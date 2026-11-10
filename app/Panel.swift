// Panel.swift — ScreenLink 控制面板窗口
//
// 两台 Mac 的统一管理入口，四个区块：
//   ① 状态总览 —— 本机 / 远端实时状态、上次同步时间（面板打开期间 5s 自动刷新）
//   ② 基础设置 —— 启用联动 / 本机角色 / 远端地址 / 登录时启动 / 测试连接
//   ③ 功能开关与生效时间窗 —— NSGridView 表格，每功能一行，改动立即生效
//   ④ 两机设置统一 —— 本机 vs 远端逐项对照，一键「远端同本机」/「本机同远端」；
//      推送走 SSH defaults write + touch reload-settings，对端引擎见文件自动重启加载
import AppKit

// MARK: - 远端状态快照
struct RemoteInfo {
    var reachable = false
    var appUp = false
    var hasDir = true
    var saver = false
    var force = false
    var keep = false
    var hbAge: Int = -1
    var settings: [String: String] = [:]
}

// MARK: - 控制面板
final class PanelController: NSObject, NSWindowDelegate {
    /// 参与对照 / 统一的功能开关（enabled / role / peer 单独处理）
    static let featureKeys = ["syncEnter", "holdRemote", "syncExit", "lockAsSaver",
                              "keepAwake", "forceHold", "wakeDisplay"]
    static let keyTitles: [String: String] = [
        "enabled": "启用联动",
        "syncEnter": "进入屏保时远端跟随",
        "holdRemote": "本机屏保时强制远端保持",
        "syncExit": "退出屏保时远端跟随",
        "lockAsSaver": "锁屏视同进入屏保",
        "keepAwake": "本机活跃时阻止远端进屏保",
        "forceHold": "强制保持本机屏保",
        "wakeDisplay": "退出时唤醒远端显示器",
        "role": "本机角色",
        "peer": "远端地址",
    ]
    static let masterFeatureList: [(String, String, String)] = [
        ("syncEnter",   "进入屏保时远端跟随",       "本机进屏保 → 远端同时进屏保"),
        ("holdRemote",  "本机屏保时强制远端保持",   "远端屏保被划掉立即拉回，禁止退出"),
        ("syncExit",    "退出屏保时远端跟随",       "本机退屏保 → 远端自动退出"),
        ("lockAsSaver", "锁屏视同进入屏保",         "直接锁屏（不跑屏保）也触发远端进入"),
        ("keepAwake",   "本机活跃时阻止远端进屏保", "本机有人在用，远端不会自己睡进屏保"),
    ]
    static let slaveFeatureList: [(String, String, String)] = [
        ("forceHold",   "强制保持本机屏保",         "被划掉自动恢复；主控在线时以主控「强制远端保持」（含时间窗）为准，本开关仅主控离线时兜底"),
        ("wakeDisplay", "退出时唤醒远端显示器",     "退出屏保时把显示器叫醒"),
    ]

    static func defaultFor(_ key: String) -> String {
        switch key {
        case "enabled", "syncEnter", "syncExit", "lockAsSaver", "keepAwake", "holdRemote",
             "forceHold", "wakeDisplay": return "on"
        case "role": return "master"
        case "peer": return "10.1.1.2"
        default: return ""      // *Win
        }
    }

    private var windowController: NSWindowController?
    private var bodyStack: NSStackView!
    private var featureStack: NSStackView!      // 功能表格容器（随角色重建）
    private var rowMap: [String: FeatureRow] = [:]
    private var builtRole: String?

    // 状态区
    private var localStateLabel: NSTextField!
    private var remoteStateLabel: NSTextField!
    private var lastSyncLabel: NSTextField!
    // 基础区
    private var enabledBox: NSButton!
    private var loginBox: NSButton!
    private var roleSeg: NSSegmentedControl!
    private var peerField: NSTextField!
    // 统一区
    private var unifyStack: NSStackView!
    private var compareGrid: NSGridView?
    private var pushBtn: NSButton!
    private var pullBtn: NSButton!
    private var unifyHint: NSTextField!

    private var remote = RemoteInfo()
    private var probing = false
    private var busy = false
    private var refreshTimer: Timer?

    // MARK: 打开 / 刷新
    func open() {
        if windowController == nil { buildWindow() }
        refresh(forceRebuild: true)
        windowController?.showWindow(nil)
        // 多屏拔插后窗口可能留在屏外 → 每次打开拉回主屏（原点 0,0 那块）中央
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        if let win = windowController?.window, let screen = mainScreen {
            let f = screen.visibleFrame
            var r = win.frame
            r.origin.x = f.midX - r.width / 2
            r.origin.y = f.midY - r.height / 2
            win.setFrame(r, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
        probeRemote()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self = self, let win = self.windowController?.window, win.isVisible else { return }
                self.updateLocalUI()
                self.probeRemote()
            }
        }
    }

    /// 菜单开关变化 / 引擎通知都会走到这里；不可见时跳过（open 会强制刷）
    func refresh(forceRebuild: Bool = false) {
        guard let win = windowController?.window, forceRebuild || win.isVisible else { return }
        if forceRebuild || builtRole != S.role {
            builtRole = S.role
            rebuildFeatureGrid()
        }
        for (_, row) in rowMap { row.update() }
        updateLocalUI()
        rebuildCompareGrid()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: 构建窗口
    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "ScreenLink 控制面板"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 420)
        win.center()
        windowController = NSWindowController(window: win)

        // 直接用窗口自带的 contentView（它由窗口管 frame）
        let content = win.contentView!
        let title = NSTextField(labelWithString: "ScreenLink 控制面板")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString:
            "两台 Mac 的统一管理：状态、基础设置、功能开关与生效时间窗、两机设置一键统一。改动立即生效。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 18
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(bodyStack)
        scroll.documentView = clip

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            clip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            clip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            bodyStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            bodyStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 6),
            bodyStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -6),
            bodyStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -8),
        ])

        buildStatusSection()
        buildBasicSection()
        buildFeatureSection()
        buildUnifySection()
    }

    private func sectionHeader(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: ① 状态总览
    private func buildStatusSection() {
        let head = NSStackView(views: [sectionHeader("状态总览")])
        head.orientation = .horizontal
        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(manualRefresh))
        refreshBtn.bezelStyle = .roundRect
        refreshBtn.font = .systemFont(ofSize: 11)
        head.addArrangedSubview(refreshBtn)
        head.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        localStateLabel = NSTextField(labelWithString: "本机：—")
        remoteStateLabel = NSTextField(labelWithString: "远端：—")
        lastSyncLabel = NSTextField(labelWithString: "上次同步：—")
        for l in [localStateLabel!, remoteStateLabel!, lastSyncLabel!] {
            l.font = .systemFont(ofSize: 12)
            l.lineBreakMode = .byWordWrapping
            l.preferredMaxLayoutWidth = 700
        }
        let grid = NSGridView(views: [
            [fieldLabel("本机"), localStateLabel],
            [fieldLabel("远端"), remoteStateLabel],
            [fieldLabel("同步"), lastSyncLabel],
        ])
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .leading

        let sec = NSStackView(views: [head, grid])
        sec.orientation = .vertical
        sec.alignment = .leading
        sec.spacing = 8
        bodyStack.addArrangedSubview(sec)
        bodyStack.addArrangedSubview(separator())
    }

    private func fieldLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: ② 基础设置
    private func buildBasicSection() {
        let head = NSStackView(views: [sectionHeader("基础设置")])
        head.orientation = .horizontal

        enabledBox = NSButton(checkboxWithTitle: "启用联动", target: self, action: #selector(toggleEnabledBox))
        loginBox = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLoginBox))
        let row1 = NSStackView(views: [enabledBox, loginBox])
        row1.orientation = .horizontal
        row1.spacing = 24

        roleSeg = NSSegmentedControl(labels: ["主控", "从动"],
                                     trackingMode: .selectOne, target: self, action: #selector(pickRoleSeg))
        peerField = NSTextField(string: S.peer)
        peerField.placeholderString = "10.1.1.2"
        peerField.translatesAutoresizingMaskIntoConstraints = false
        peerField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let savePeerBtn = NSButton(title: "保存地址", target: self, action: #selector(savePeer))
        savePeerBtn.bezelStyle = .roundRect
        let testBtn = NSButton(title: "测试连接", target: self, action: #selector(testPeer))
        testBtn.bezelStyle = .roundRect
        let row2 = NSStackView(views: [fieldLabel("本机角色"), roleSeg,
                                       fieldLabel("远端地址"), peerField, savePeerBtn, testBtn])
        row2.orientation = .horizontal
        row2.spacing = 10

        let sec = NSStackView(views: [head, row1, row2])
        sec.orientation = .vertical
        sec.alignment = .leading
        sec.spacing = 8
        bodyStack.addArrangedSubview(sec)
        bodyStack.addArrangedSubview(separator())
    }

    // MARK: ③ 功能开关与生效时间窗
    private func buildFeatureSection() {
        let head = NSStackView(views: [sectionHeader("功能开关与生效时间窗")])
        head.orientation = .horizontal
        featureStack = NSStackView()
        featureStack.orientation = .vertical
        featureStack.alignment = .leading
        featureStack.spacing = 10
        let sec = NSStackView(views: [head, featureStack])
        sec.orientation = .vertical
        sec.alignment = .leading
        sec.spacing = 8
        bodyStack.addArrangedSubview(sec)
        bodyStack.addArrangedSubview(separator())
    }

    private func rebuildFeatureGrid() {
        rowMap.removeAll()
        featureStack.arrangedSubviews.forEach { featureStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let features = builtRole == "slave" ? PanelController.slaveFeatureList : PanelController.masterFeatureList
        var rows: [[NSView]] = [[
            fieldLabel("启用"), fieldLabel("功能"), fieldLabel("生效状态"),
            fieldLabel("仅在时段生效"), fieldLabel("开始"), fieldLabel(""), fieldLabel("结束"),
        ]]
        for f in features {
            let row = FeatureRow(key: f.0, title: f.1, subtitle: f.2, owner: self)
            rowMap[f.0] = row
            rows.append([row.enableBox, row.nameStack, row.stateLabel, row.winCheck,
                         row.startPick, row.dash, row.endPick])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 3).xPlacement = .center
        grid.column(at: 5).xPlacement = .center
        featureStack.addArrangedSubview(grid)
        featureStack.addArrangedSubview(fieldLabel(
            builtRole == "slave"
            ? "当前角色：从动 —— 以上为本机被动看护相关功能"
            : "当前角色：主控 —— 以上为驱动远端相关功能；切换角色后此处自动跟随"))
    }

    // MARK: ④ 两机设置统一
    private func buildUnifySection() {
        let head = NSStackView(views: [sectionHeader("两机设置统一")])
        head.orientation = .horizontal

        unifyHint = NSTextField(labelWithString:
            "对照本机与远端的当前设置；「远端同本机」经 SSH 写入并通知远端自动重载。角色按互补、地址按互指判一致。")
        unifyHint.font = .systemFont(ofSize: 11)
        unifyHint.textColor = .secondaryLabelColor
        unifyHint.lineBreakMode = .byWordWrapping
        unifyHint.preferredMaxLayoutWidth = 700

        pushBtn = NSButton(title: "远端同本机 →", target: self, action: #selector(unifyPush))
        pushBtn.bezelStyle = .roundRect
        pullBtn = NSButton(title: "← 本机同远端", target: self, action: #selector(unifyPull))
        pullBtn.bezelStyle = .roundRect
        let btnRow = NSStackView(views: [pushBtn, pullBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 12

        unifyStack = NSStackView()
        unifyStack.orientation = .vertical
        unifyStack.alignment = .leading
        unifyStack.spacing = 10

        let sec = NSStackView(views: [head, unifyHint, unifyStack, btnRow])
        sec.orientation = .vertical
        sec.alignment = .leading
        sec.spacing = 8
        bodyStack.addArrangedSubview(sec)
    }

    private func rebuildCompareGrid() {
        if let old = compareGrid {
            unifyStack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        var rows: [[NSView]] = [[
            fieldLabel("设置"), fieldLabel("本机"), fieldLabel("远端"), fieldLabel("一致"),
        ]]
        let local = localSettings()
        let myIP = Self.localLANIP()
        let keys = ["enabled"] + PanelController.featureKeys + ["role", "peer"]
        for k in keys {
            let lv = displayValue(k, local)
            let rv = remote.reachable ? displayValue(k, remote.settings) : "—（不可达）"
            // 角色应互补、地址应互指，这两行按规则判一致，不能直接比字符串
            let same: Bool
            if k == "role" {
                same = remote.reachable
                    && (remote.settings[k] ?? PanelController.defaultFor(k)) == (S.role == "master" ? "slave" : "master")
            } else if k == "peer" {
                same = !remote.reachable ? false : (myIP.map { (remote.settings[k] ?? "") == $0 } ?? true)
            } else {
                same = remote.reachable && lv == rv
            }
            let mark = NSTextField(labelWithString: remote.reachable ? (same ? "✓" : "✗") : "—")
            mark.font = .systemFont(ofSize: 12, weight: .semibold)
            mark.textColor = !remote.reachable ? .tertiaryLabelColor : (same ? .systemGreen : .systemRed)
            let name = NSTextField(labelWithString: PanelController.keyTitles[k] ?? k)
            name.font = .systemFont(ofSize: 12)
            let l1 = NSTextField(labelWithString: lv)
            let l2 = NSTextField(labelWithString: rv)
            for l in [l1, l2] {
                l.font = .systemFont(ofSize: 12)
                l.lineBreakMode = .byTruncatingTail
            }
            if !remote.reachable { l2.textColor = .tertiaryLabelColor }
            rows.append([name, l1, l2, mark])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 3).xPlacement = .center
        unifyStack.insertArrangedSubview(grid, at: 0)
        compareGrid = grid
    }

    // MARK: 设置值读写 / 展示
    private func localSettings() -> [String: String] {
        var r: [String: String] = ["enabled": S.enabled ? "on" : "off",
                                   "role": S.role, "peer": S.peer]
        for k in PanelController.featureKeys {
            r[k] = UserDefaults.standard.bool(forKey: k) ? "on" : "off"
            r[k + "Win"] = S.windowEnabled(k) ? S.window(k) : ""
            r[k + "WinOn"] = S.windowEnabled(k) ? "on" : "off"
        }
        return r
    }

    /// 对照表展示用的「生效时段」：未勾选/未配 = 空（全天）
    private func effWin(_ s: [String: String], _ k: String) -> String {
        let w = s[k + "Win"] ?? ""
        guard !w.isEmpty else { return "" }
        if let on = s[k + "WinOn"] { return on == "on" ? w : "" }
        return w
    }

    private func displayValue(_ key: String, _ s: [String: String]) -> String {
        let v = s[key] ?? PanelController.defaultFor(key)
        if PanelController.featureKeys.contains(key) {
            let w = effWin(s, key)
            return (v == "on" ? "开" : "关") + " · " + (w.isEmpty ? "全天" : w)
        }
        if key == "role" { return v == "master" ? "主控" : "从动" }
        return v
    }

    private func updateLocalUI() {
        enabledBox.state = S.enabled ? .on : .off
        loginBox.state = loginItemEnabled() ? .on : .off
        roleSeg.selectedSegment = S.role == "master" ? 0 : 1
        if peerField.stringValue != S.peer,
           peerField.currentEditor() == nil {
            peerField.stringValue = S.peer
        }
        localStateLabel.stringValue = localStatusText()
        remoteStateLabel.stringValue = remoteStatusText()
        if let t = Engine.shared.lastRemoteSync {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            lastSyncLabel.stringValue = f.string(from: t)
        } else {
            lastSyncLabel.stringValue = "—"
        }
        pushBtn.isEnabled = !busy
        pullBtn.isEnabled = !busy && remote.reachable
    }

    private func localStatusText() -> String {
        var p: [String] = [S.role == "master" ? "主控" : "从动",
                           S.enabled ? "联动已启用" : "联动已停用"]
        p.append(Engine.shared.localActive ? "屏保/锁屏中" : "活跃")
        if displayAsleep() { p.append("显示器休眠") }
        if fileExists(STATE_KEEP) { p.append("保活中") }
        if fileExists(STATE_FORCE) { p.append("强制保持下发中") }
        return p.joined(separator: " · ")
    }

    private func remoteStatusText() -> String {
        guard remote.reachable else { return "\(S.peer) 不可达" }
        var p: [String] = [remote.appUp ? "App 运行中" : "App 未运行"]
        p.append(remote.saver ? "屏保中" : "屏保未开启")
        if remote.force { p.append("强制保持") }
        if remote.keep { p.append("保活中") }
        p.append(remote.hbAge >= 0 ? "心跳 \(remote.hbAge)s 前" : "无心跳")
        if let r = remote.settings["role"] { p.append(r == "master" ? "主控" : "从动") }
        return p.joined(separator: " · ")
    }

    // MARK: 远端探测
    @objc private func manualRefresh() {
        updateLocalUI()
        probeRemote()
    }

    private func probeRemote() {
        guard !probing else { return }
        probing = true
        let peer = S.peer
        let cmd = "echo __FLAGS; if [ -d ~/sscreenlink ]; then cd ~/sscreenlink; "
            + "test -f saver-wanted && echo SAVER=1 || echo SAVER=0; "
            + "test -f force-hold && echo FORCE=1 || echo FORCE=0; "
            + "test -f keep-awake && echo KEEP=1 || echo KEEP=0; "
            + "if [ -f heartbeat ]; then echo HBAGE=$(( $(date +%s) - $(stat -f %m heartbeat) )); else echo HBAGE=-1; fi; "
            + "else echo NODIR=1; fi; "
            + "pgrep -f 'ScreenLink.app/Contents/MacOS/ScreenLink' >/dev/null && echo APP=1 || echo APP=0; "
            + "echo __PLIST; defaults export com.think.screenlink.app - 2>/dev/null"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                           "-o", "StrictHostKeyChecking=accept-new", peer, cmd]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var out = ""
            do {
                try p.run()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
            } catch { out = "" }
            let info = Self.parseProbe(out)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.probing = false
                self.remote = info
                self.updateLocalUI()
                self.rebuildCompareGrid()
            }
        }
    }

    static func parseProbe(_ out: String) -> RemoteInfo {
        var info = RemoteInfo()
        guard let plistRange = out.range(of: "__PLIST") else { return info }
        let flagsPart = String(out[out.startIndex..<plistRange.lowerBound])
        let plistPart = String(out[plistRange.upperBound...])
        var sawFlag = false
        for line in flagsPart.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            sawFlag = true
            switch String(kv[0]) {
            case "SAVER": info.saver = kv[1] == "1"
            case "FORCE": info.force = kv[1] == "1"
            case "KEEP": info.keep = kv[1] == "1"
            case "APP": info.appUp = kv[1] == "1"
            case "HBAGE": info.hbAge = Int(kv[1]) ?? -1
            case "NODIR": info.hasDir = false
            default: break
            }
        }
        info.reachable = sawFlag
        if let data = plistPart.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            var s: [String: String] = [:]
            for (k, v) in plist {
                if let b = v as? Bool { s[k] = b ? "on" : "off" }
                else if let str = v as? String { s[k] = str }
            }
            info.settings = s
        }
        return info
    }

    // MARK: 基础设置动作
    @objc private func toggleEnabledBox() {
        S.enabled = enabledBox.state == .on
        appLog("switch(panel): enabled=\(S.enabled)")
        Engine.shared.restart()
        Engine.shared.applySettingChange()
        updateLocalUI()
    }

    @objc private func toggleLoginBox() {
        setLoginItem(loginBox.state == .on)
        updateLocalUI()
    }

    @objc private func pickRoleSeg() {
        let role = roleSeg.selectedSegment == 0 ? "master" : "slave"
        guard role != S.role else { return }
        S.role = role
        appLog("role(panel) -> \(role)")
        Engine.shared.restart()
        refresh(forceRebuild: true)
    }

    @objc private func savePeer() {
        let v = peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v != S.peer else { return }
        S.peer = v
        appLog("peer(panel) -> \(v)")
        Engine.shared.restart()
        updateLocalUI()
        probeRemote()
    }

    @objc private func testPeer() {
        (NSApp.delegate as? AppDelegate)?.testRemote()
    }

    // MARK: 两机统一动作
    @objc private func unifyPush() {
        guard !busy else { return }
        busy = true
        updateLocalUI()
        unifyHint.stringValue = "正在统一远端…（SSH 写入设置并通知重载）"
        let peer = S.peer
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var parts: [String] = ["defaults write com.think.screenlink.app enabled -bool \(S.enabled)"]
            for k in PanelController.featureKeys {
                parts.append("defaults write com.think.screenlink.app \(k) -bool \(UserDefaults.standard.bool(forKey: k))")
                parts.append("defaults write com.think.screenlink.app \(k)Win -string '\(S.window(k))'")
                parts.append("defaults write com.think.screenlink.app \(k)WinOn -bool \(S.windowEnabled(k))")
            }
            parts.append("defaults write com.think.screenlink.app role -string \(S.role == "master" ? "slave" : "master")")
            if let ip = Self.localLANIP() {
                parts.append("defaults write com.think.screenlink.app peer -string \(ip)")
            }
            parts.append("mkdir -p ~/sscreenlink && touch ~/sscreenlink/reload-settings")
            sshShell(peer, parts.joined(separator: "; "))
            appLog("panel: unify push -> \(peer) done")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.unifyHint.stringValue = "统一指令已发送，远端将自动重载设置；对照表稍后自动刷新。"
                self.probeRemote()
                self.updateLocalUI()
            }
        }
    }

    @objc private func unifyPull() {
        guard !busy, remote.reachable else { return }
        let rs = remote.settings
        func val(_ k: String) -> String { rs[k] ?? PanelController.defaultFor(k) }
        S.enabled = val("enabled") == "on"
        for k in PanelController.featureKeys {
            UserDefaults.standard.set(val(k) == "on", forKey: k)
            S.setWindow(k, rs[k + "Win"] ?? "")
            let on: Bool
            if let o = rs[k + "WinOn"] { on = o == "on" }
            else { on = !(rs[k + "Win"] ?? "").isEmpty }   // 远端旧配置：有时段 = 勾选
            S.setWindowEnabled(k, on)
        }
        // role / peer 不参与拉取：两机角色必须互补、peer 必须互指，拉过来就坏了
        appLog("panel: unify pull <- \(S.peer) done")
        Engine.shared.restart()
        Engine.shared.applySettingChange()
        unifyHint.stringValue = "已按远端设置更新本机（角色/地址保持互补互指，不拉取）。"
        refresh(forceRebuild: true)
        probeRemote()
    }

    static func localLANIP() -> String? {
        for ifc in ["en0", "en1"] {
            let ip = shOut(["/sbin/ipconfig", "getifaddr", ifc])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty { return ip }
        }
        return nil
    }

    // MARK: 行内控件事件（由 FeatureRow 转发）
    fileprivate func featureToggled(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        appLog("switch(panel): \(key)=\(on) win=\(S.window(key).isEmpty ? "全天" : S.window(key))")
        Engine.shared.applySettingChange()
        rowMap[key]?.update()
        rebuildCompareGrid()
    }

    fileprivate func windowToggled(_ key: String, _ on: Bool) {
        // 取消勾选只关 WinOn，不清已配时段：再勾回来还是原来填的时间
        S.setWindowEnabled(key, on)
        if on && parseWindow(S.window(key)) == nil {
            S.setWindow(key, rowMap[key]?.defaultWindow() ?? "22:00-07:00")
        }
        appLog("window(panel): \(key) winOn=\(on) win=\(S.window(key).isEmpty ? "未配" : S.window(key))")
        Engine.shared.applySettingChange(keepAliveSync: false)
        rowMap[key]?.update()
        rebuildCompareGrid()
    }

    fileprivate func timeChanged(_ key: String) {
        guard let row = rowMap[key] else { return }
        let a = row.startText(), b = row.endText()
        guard let am = parseTimeOfDay(a), let bm = parseTimeOfDay(b), am != bm else {
            row.update()   // 起止相同无意义，回滚显示为已存值
            return
        }
        S.setWindow(key, "\(a)-\(b)")
        appLog("window(panel): \(key)=\(a)-\(b)")
        Engine.shared.applySettingChange(keepAliveSync: false)
        row.update()
        rebuildCompareGrid()
    }
}

// MARK: - 控制面板 · 单行（控件直接进外层 NSGridView，列自动对齐）
final class FeatureRow {
    let key: String
    let enableBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let winCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let stateLabel = NSTextField(labelWithString: "—")
    let startPick: NSDatePicker
    let endPick: NSDatePicker
    let dash = NSTextField(labelWithString: "至")
    let nameStack: NSStackView
    private let owner: PanelController

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(key: String, title: String, subtitle: String, owner: PanelController) {
        self.key = key
        self.owner = owner

        func picker() -> NSDatePicker {
            let p = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 76, height: 24))
            p.datePickerStyle = .textField
            p.datePickerElements = .hourMinute
            p.datePickerMode = .single
            p.calendar = Calendar.current
            p.locale = Locale(identifier: "en_GB")
            p.dateValue = Date()
            p.font = .systemFont(ofSize: 12)
            // 失焦/回车即提交 action：否则点开关时编辑中的时间不会保存，
            // 随后 update() 用已存值回写就把刚填的内容冲掉（属性在 cell 上）
            p.cell?.sendsActionOnEndEditing = true
            p.translatesAutoresizingMaskIntoConstraints = false
            return p
        }
        startPick = picker()
        endPick = picker()

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        nameStack = NSStackView(views: [name, sub])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2

        stateLabel.font = .systemFont(ofSize: 11)
        dash.font = .systemFont(ofSize: 11)
        dash.alignment = .center
        dash.textColor = .secondaryLabelColor

        // 列宽：NSGridView 取每列单元格约束宽度的最大值，钉住后整表对齐
        enableBox.widthAnchor.constraint(equalToConstant: 20).isActive = true
        winCheck.widthAnchor.constraint(equalToConstant: 20).isActive = true
        nameStack.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stateLabel.widthAnchor.constraint(equalToConstant: 116).isActive = true
        dash.widthAnchor.constraint(equalToConstant: 16).isActive = true
        startPick.widthAnchor.constraint(equalToConstant: 76).isActive = true
        endPick.widthAnchor.constraint(equalToConstant: 76).isActive = true

        // target/action 必须在所有存储属性初始化完成后再指向 self
        enableBox.target = self
        enableBox.action = #selector(toggleFeature)
        winCheck.target = self
        winCheck.action = #selector(toggleWin)
        startPick.target = self
        startPick.action = #selector(timePicked)
        endPick.target = self
        endPick.action = #selector(timePicked)
        update()
    }

    /// 勾选「仅在时段生效」时的默认窗口：取当前已存值，没有则 22:00-07:00
    func defaultWindow() -> String {
        let cur = S.window(key)
        return parseWindow(cur) != nil ? cur : "22:00-07:00"
    }

    func startText() -> String { FeatureRow.hmFormatter.string(from: startPick.dateValue) }
    func endText() -> String { FeatureRow.hmFormatter.string(from: endPick.dateValue) }

    /// 把 UserDefaults 里的当前值同步到控件（外部刷控件时防递归：先摘 target）
    func update() {
        let on = UserDefaults.standard.bool(forKey: key)
        enableBox.state = on ? .on : .off

        let w = S.window(key)
        let checked = S.windowEnabled(key)
        let hasWin = checked && parseWindow(w) != nil
        winCheck.state = checked ? .on : .off

        let inWin = S.inWindow(key)
        if !on { stateLabel.stringValue = "已关闭" }
        else if !hasWin { stateLabel.stringValue = "全天生效" }
        else { stateLabel.stringValue = inWin ? "生效中 · \(w)" : "未生效 · \(w)" }
        stateLabel.textColor = (on && inWin) ? .systemGreen : .secondaryLabelColor

        if hasWin, let win = parseWindow(w) {
            // 正在编辑中的选择器不回写，否则刷新/开关通知会冲掉用户刚填的值
            if startPick.currentEditor() == nil { setPicker(startPick, minuteOfDay: win.start) }
            if endPick.currentEditor() == nil { setPicker(endPick, minuteOfDay: win.end) }
        }
        let controls: [NSControl] = [winCheck, startPick, endPick]
        for c in controls { c.target = nil }
        winCheck.isEnabled = on
        startPick.isEnabled = on && hasWin
        endPick.isEnabled = on && hasWin
        winCheck.target = self; winCheck.action = #selector(toggleWin)
        startPick.target = self; startPick.action = #selector(timePicked)
        endPick.target = self; endPick.action = #selector(timePicked)
    }

    private func setPicker(_ p: NSDatePicker, minuteOfDay: Int) {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        if let d = Calendar.current.date(from: comps) {
            p.target = nil
            p.dateValue = d
            p.target = self
        }
    }

    @objc private func toggleFeature() { owner.featureToggled(key, enableBox.state == .on) }
    @objc private func toggleWin() { owner.windowToggled(key, winCheck.state == .on) }
    @objc private func timePicked() { owner.timeChanged(key) }
}
