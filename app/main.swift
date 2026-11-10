// main.swift — ScreenLink 菜单栏应用
//
// 单实例常驻菜单栏（LSUIElement），所有能力都可单独开关：
//   启用联动 / 进屏保同步 / 退屏保同步 / 锁屏同步 / 阻止远端屏保 / 强制保持 / 唤醒显示器
// 开关与生效时间段统一在「控制面板」窗口里管理（PanelController）
import AppKit
import Darwin

// MARK: - 单实例锁
// 已有实例在跑时，不静默退出，而是让它把菜单栏图标显示出来（= 用户又点了一次 App）。
let SHOW_NOTIFICATION = "com.think.screenlink.show"
let HIDE_NOTIFICATION = "com.think.screenlink.hide"
let lockFD = open("/tmp/screenlink-app.lock", O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name(SHOW_NOTIFICATION), object: nil, userInfo: nil, deliverImmediately: true)
    usleep(250_000)   // 留出投递时间，确保前台实例收到
    exit(0)
}

S.register()

// MARK: - 登录项
func loginPlistPath() -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/com.think.screenlink.app.plist"
}

func loginItemEnabled() -> Bool {
    FileManager.default.fileExists(atPath: loginPlistPath())
}

func setLoginItem(_ on: Bool) {
    let path = loginPlistPath()
    if on {
        guard let exe = Bundle.main.executablePath else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.think.screenlink.app</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? plist.write(toFile: path, atomically: true, encoding: .utf8)
        appLog("login item: enabled (\(exe))")
    } else {
        _ = sh(["/bin/launchctl", "bootout", "gui/\(getuid())/com.think.screenlink.app"])
        try? FileManager.default.removeItem(atPath: path)
        appLog("login item: disabled")
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    // 需要动态刷新的项
    var headerItem: NSMenuItem!
    var localStateItem: NSMenuItem!
    var remoteStateItem: NSMenuItem!
    var enableItem: NSMenuItem!
    var syncItems: [String: NSMenuItem] = [:]      // key -> item
    var roleItems: [String: NSMenuItem] = [:]
    var loginItem: NSMenuItem!
    var testItem: NSMenuItem!
    var masterOnly: [NSMenuItem] = []
    var slaveOnly: [NSMenuItem] = []
    var panelController: PanelController?

    var remoteText = "检测中…"
    var probing = false
    var statusHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildMenu()
        Engine.shared.onChange = { [weak self] in self?.refresh() }
        Engine.shared.restart()
        refresh()

        // 再次打开 App（已有实例在跑）→ 重新显示菜单栏图标
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(SHOW_NOTIFICATION), object: nil, queue: .main
        ) { [weak self] _ in
            self?.showStatusItem()
        }
        // 反向：允许外部/脚本把它收进后台
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(HIDE_NOTIFICATION), object: nil, queue: .main
        ) { [weak self] _ in
            self?.hideStatusItem()
        }

        appLog("APP launch pid=\(ProcessInfo.processInfo.processIdentifier) role=\(S.role) peer=\(S.peer)")
    }

    // 用户再次点开 App（open -a / 双击 / Spotlight）时，macOS 会给运行中的实例发 reopen
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusItem()
        return false
    }

    // MARK: 菜单栏 显示 / 隐藏
    func hideStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusHidden = true
        appLog("menu bar: hidden (running in background, relaunch app to bring it back)")
    }

    func showStatusItem() {
        guard statusItem == nil else { return }   // 已显示则无需处理
        buildStatusItem()
        statusHidden = false
        refresh()
        appLog("menu bar: shown (app reopened)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.stop()
    }

    // MARK: 状态栏图标
    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu
        updateIcon()
    }

    func updateIcon() {
        // 图标被隐藏（后台运行）时不做任何绘制，避免空引用
        guard let button = statusItem?.button else { return }
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let on = S.enabled
            let active = Engine.shared.localActive && on
            let stroke = NSColor.black.withAlphaComponent(on ? 1.0 : 0.32)
            let lw: CGFloat = 1.5

            func screen(_ x: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x, y: 3.6, width: 7.4, height: 10.2),
                             xRadius: 1.7, yRadius: 1.7)
            }
            let l = screen(1.1)
            let r = screen(13.5)
            for p in [l, r] {
                p.lineWidth = lw
                if active {
                    NSColor.black.withAlphaComponent(0.30).setFill()
                    p.fill()
                }
                stroke.setStroke()
                p.stroke()
            }
            // 中间链接
            let link = NSBezierPath()
            link.move(to: NSPoint(x: 8.7, y: 8.7))
            link.line(to: NSPoint(x: 13.3, y: 8.7))
            link.lineWidth = lw
            link.lineCapStyle = .round
            stroke.setStroke()
            link.stroke()

            // 运行中：中点一个小圆点（表示正在联动）
            if on {
                let dot = NSBezierPath(ovalIn: NSRect(x: 10.0, y: 7.7, width: 2.0, height: 2.0))
                NSColor.black.withAlphaComponent(active ? 1.0 : 0.55).setFill()
                dot.fill()
            }
            return true
        }
        img.isTemplate = true
        button.image = img
    }

    // MARK: 菜单构建
    func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        headerItem = NSMenuItem(title: "屏保联动", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        localStateItem = NSMenuItem(title: "本机：—", action: nil, keyEquivalent: "")
        localStateItem.isEnabled = false
        menu.addItem(localStateItem)

        remoteStateItem = NSMenuItem(title: "远端：—", action: nil, keyEquivalent: "")
        remoteStateItem.isEnabled = false
        menu.addItem(remoteStateItem)

        menu.addItem(.separator())

        enableItem = NSMenuItem(title: "启用联动", action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.image = symbol("bolt.horizontal.circle")
        menu.addItem(enableItem)

        let panelItem = NSMenuItem(title: "控制面板…", action: #selector(openPanel), keyEquivalent: ",")
        panelItem.target = self
        panelItem.image = symbol("switch.2")
        menu.addItem(panelItem)

        // ---- 主控行为
        let syncMenu = NSMenu()
        syncItems["syncEnter"] = makeToggle("进入屏保时远端跟随", key: "syncEnter",
                                            symbol: "arrow.right.to.line", in: syncMenu)
        syncItems["holdRemote"] = makeToggle("本机屏保时强制远端保持（禁止退出）", key: "holdRemote",
                                             symbol: "hand.raised", in: syncMenu)
        syncItems["syncExit"] = makeToggle("退出屏保时远端跟随", key: "syncExit",
                                           symbol: "arrow.left.to.line", in: syncMenu)
        syncItems["lockAsSaver"] = makeToggle("锁屏视同进入屏保", key: "lockAsSaver",
                                             symbol: "lock", in: syncMenu)
        syncItems["keepAwake"] = makeToggle("本机活跃时阻止远端进屏保", key: "keepAwake",
                                           symbol: "eye", in: syncMenu)
        let syncRoot = NSMenuItem(title: "主控行为", action: nil, keyEquivalent: "")
        syncRoot.image = symbol("slider.horizontal.3")
        syncRoot.submenu = syncMenu
        menu.addItem(syncRoot)
        masterOnly.append(syncRoot)

        // ---- 从动行为
        let slaveMenu = NSMenu()
        syncItems["forceHold"] = makeToggle("强制保持本机屏保（被划掉自动恢复）", key: "forceHold",
                                            symbol: "arrow.clockwise", in: slaveMenu)
        syncItems["wakeDisplay"] = makeToggle("退出时唤醒远端显示器", key: "wakeDisplay",
                                              symbol: "sun.max", in: slaveMenu)
        let slaveRoot = NSMenuItem(title: "从动行为", action: nil, keyEquivalent: "")
        slaveRoot.image = symbol("slider.horizontal.3")
        slaveRoot.submenu = slaveMenu
        menu.addItem(slaveRoot)
        slaveOnly.append(slaveRoot)

        menu.addItem(.separator())

        // ---- 角色
        let roleMenu = NSMenu()
        for (key, title, sym) in [("master", "主控（本机驱动远端）", "desktopcomputer"),
                                  ("slave", "从动（本机被动跟随）", "square.stack.3d.down.right")] {
            let it = NSMenuItem(title: title, action: #selector(pickRole(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.image = symbol(sym)
            roleMenu.addItem(it)
            roleItems[key] = it
        }
        let roleRoot = NSMenuItem(title: "本机角色", action: nil, keyEquivalent: "")
        roleRoot.image = symbol("person.2")
        roleRoot.submenu = roleMenu
        menu.addItem(roleRoot)

        // ---- 远端地址
        let peerItem = NSMenuItem(title: "远端地址…", action: #selector(editPeer), keyEquivalent: "")
        peerItem.target = self
        peerItem.image = symbol("network")
        menu.addItem(peerItem)

        testItem = NSMenuItem(title: "测试远端连接", action: #selector(testRemote), keyEquivalent: "")
        testItem.target = self
        testItem.image = symbol("antenna.radiowaves.left.and.right")
        menu.addItem(testItem)
        masterOnly.append(testItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.image = symbol("power")
        menu.addItem(loginItem)

        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        logItem.image = symbol("doc.text.magnifyingglass")
        menu.addItem(logItem)

        let aboutItem = NSMenuItem(title: "关于 ScreenLink", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = symbol("info.circle")
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let hideItem = NSMenuItem(title: "隐藏菜单栏图标（后台继续运行）",
                                  action: #selector(hideMenuBar), keyEquivalent: "")
        hideItem.target = self
        hideItem.image = symbol("eye.slash")
        menu.addItem(hideItem)

        let quit = NSMenuItem(title: "退出 ScreenLink", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = symbol("xmark.circle")
        menu.addItem(quit)
    }

    func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.size = NSSize(width: 15, height: 15)
        return img
    }

    func makeToggle(_ title: String, key: String, symbol sym: String, in target: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = key
        it.image = symbol(sym)
        target.addItem(it)
        return it
    }

    // MARK: 刷新
    func refresh() {
        let isMaster = S.role == "master"
        headerItem.title = S.enabled ? "屏保联动 · " + (isMaster ? "主控" : "从动")
                                     : "屏保联动 · 已停用"
        localStateItem.title = "本机：" + localStateText()
        remoteStateItem.title = "远端：" + (isMaster ? remoteText : "被动接收（不主动连接）")
        remoteStateItem.isHidden = false

        enableItem.state = S.enabled ? .on : .off

        for (key, item) in syncItems {
            item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            if S.enabled == false { item.isEnabled = false } else { item.isEnabled = true }
        }
        panelController?.refresh()
        for (_, it) in roleItems { it.state = .off }
        roleItems[S.role]?.state = .on
        loginItem.state = loginItemEnabled() ? .on : .off

        for it in masterOnly { it.isHidden = !isMaster }
        for it in slaveOnly { it.isHidden = isMaster }
        updateIcon()
    }

    func localStateText() -> String {
        guard S.enabled else { return "已停用" }
        var parts: [String] = []
        if Engine.shared.localActive { parts.append("屏保/锁屏中") }
        if fileExists(STATE_FORCE) { parts.append("强制远端保持中") }
        if displayAsleep() { parts.append("显示器已休眠") }
        if fileExists(STATE_KEEP) { parts.append("保活中") }
        if Engine.shared.mode == "slave" && fileExists(STATE_SAVER) { parts.append("主控要求屏保") }
        if Engine.shared.mode == "slave" && fileExists(STATE_FORCE) { parts.append("主控强制保持") }
        if let t = Engine.shared.lastRemoteSync, Date().timeIntervalSince(t) < 6 {
            parts.append("刚刚同步")
        }
        return parts.isEmpty ? "正常（活跃）" : parts.joined(separator: " · ")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        if S.role == "master" && S.enabled { probeRemote() }
    }

    // MARK: 远端探测
    func probeRemote() {
        guard !probing else { return }
        probing = true
        let peer = S.peer
        let cmd = "test -f '\(STATE_SAVER)' && echo SAVER || echo NOSAVER; "
            + "pgrep -f 'ScreenLink.app/Contents/MacOS/ScreenLink' >/dev/null && echo APPUP || echo APPDOWN"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                           "-o", "StrictHostKeyChecking=accept-new", peer, cmd]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var out = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(data: data, encoding: .utf8) ?? ""
            } catch { out = "" }
            let ok = out.contains("APPUP") || out.contains("SAVER") || out.contains("NOSAVER")
            var text: String
            if !ok {
                text = "\(peer) 不可达"
            } else {
                let saver = out.contains("SAVER")
                let up = out.contains("APPUP")
                text = "\(peer) · 屏保\(saver ? "中" : "未开启") · \(up ? "已连接" : "未运行 App")"
            }
            DispatchQueue.main.async {
                self?.remoteText = text
                self?.remoteStateItem.title = "远端：" + text
                self?.probing = false
            }
        }
    }

    // MARK: 动作
    @objc func toggleEnabled() {
        S.enabled.toggle()
        appLog("switch: enabled=\(S.enabled)")
        Engine.shared.restart()
        Engine.shared.applySettingChange()
        refresh()
    }

    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let v = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(v, forKey: key)
        appLog("switch: \(key)=\(v) win=\(S.window(key).isEmpty ? "全天" : S.window(key))")
        sender.state = v ? .on : .off
        Engine.shared.applySettingChange()
        refresh()
    }

    @objc func openPanel() {
        if panelController == nil { panelController = PanelController() }
        panelController?.open()
    }

    @objc func pickRole(_ sender: NSMenuItem) {
        guard let role = sender.representedObject as? String else { return }
        S.role = role
        appLog("role -> \(role)")
        Engine.shared.restart()
        remoteText = role == "master" ? "检测中…" : "—"
        refresh()
        if role == "slave" && !sessionLocked() {
            // 切到从动：提示需要授权（首次会弹系统事件授权）
        }
    }

    @objc func editPeer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "远端地址"
        alert.informativeText = "主控将通过 SSH（免密）驱动这台机器的屏保。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = S.peer
        field.placeholderString = "10.1.1.2"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                S.peer = v
                appLog("peer -> \(v)")
                remoteText = "检测中…"
                Engine.shared.restart()
                refresh()
            }
        }
    }

    @objc func testRemote() {
        NSApp.activate(ignoringOtherApps: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                       "-o", "StrictHostKeyChecking=accept-new", S.peer,
                       "echo OK; test -f '\(STATE_SAVER)' && echo SAVER || echo NOSAVER; pgrep -f 'ScreenLink.app/Contents/MacOS/ScreenLink' >/dev/null && echo APPUP || echo APPDOWN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var out = ""
        do {
            try p.run()
            out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
        } catch { out = "" }
        let alert = NSAlert()
        if out.contains("OK") {
            alert.messageText = "远端 \(S.peer) 连接正常"
            var detail = "SSH 免密可用。"
            detail += out.contains("APPUP") ? "\n远端 ScreenLink 正在运行。" : "\n远端 ScreenLink 未运行（远端屏保不会跟随）。"
            detail += out.contains("SAVER") ? "\n当前远端处于屏保状态。" : "\n当前远端未处于屏保。"
            alert.informativeText = detail
        } else {
            alert.messageText = "远端 \(S.peer) 连接失败"
            alert.informativeText = "请确认：① 已开启远程登录；② 已配置免密 SSH（ssh-copy-id）；③ 地址正确。"
        }
        alert.runModal()
    }

    @objc func toggleLogin() {
        setLoginItem(!loginItemEnabled())
        refresh()
    }

    @objc func hideMenuBar() {
        let firstTime = !UserDefaults.standard.bool(forKey: "hideHintShown")
        hideStatusItem()
        if firstTime {
            UserDefaults.standard.set(true, forKey: "hideHintShown")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "已隐藏菜单栏图标"
            alert.informativeText = "屏保联动仍在后台运行，两台机器照常同步。\n\n想重新显示图标：再点一次 ScreenLink 即可（访达 / 启动台 / Spotlight / 程序坞都行）。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: APP_LOG_PATH) {
            touchFile(APP_LOG_PATH)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: APP_LOG_PATH))
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.1"
        alert.messageText = "ScreenLink \(ver)"
        alert.informativeText = """
        两台 Mac 屏保联动。

        主控：监听本机屏保 / 锁屏 / 显示器休眠，实时同步到远端。
        从动：被动看护屏保引擎，被划掉也能自动恢复。

        配置与日志：\(DIR_PATH)
        运行日志：\(APP_LOG_PATH)
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func quitApp() {
        appLog("APP quit by user")
        NSApp.terminate(nil)
    }
}

// MARK: - 控制面板窗口
// 所有功能开关 + 生效时间段统一在这里管理：
// 每个功能一行 —— [启用开关] 名称 · 生效状态 | [仅在时段生效] [起] 至 [止]
final class PanelController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var bodyStack: NSStackView!
    private var rowMap: [String: FeatureRow] = [:]
    private var builtRole: String?

    /// (key, 显示名, 说明)
    static let masterFeatures: [(String, String, String)] = [
        ("syncEnter",   "进入屏保时远端跟随",       "本机进屏保 → 远端同时进屏保"),
        ("holdRemote",  "本机屏保时强制远端保持",   "远端屏保被划掉立即拉回，禁止退出"),
        ("syncExit",    "退出屏保时远端跟随",       "本机退屏保 → 远端自动退出"),
        ("lockAsSaver", "锁屏视同进入屏保",         "直接锁屏（不跑屏保）也触发远端进入"),
        ("keepAwake",   "本机活跃时阻止远端进屏保", "本机有人在用，远端不会自己睡进屏保"),
    ]
    static let slaveFeatures: [(String, String, String)] = [
        ("forceHold",   "强制保持本机屏保",         "屏保被划掉时自动恢复（主控下发时以主控为准）"),
        ("wakeDisplay", "退出时唤醒远端显示器",     "退出屏保时把显示器叫醒"),
    ]

    // MARK: 打开 / 刷新
    func open() {
        if windowController == nil { buildWindow() }
        refresh(forceRebuild: true)
        windowController?.showWindow(nil)
        // 不可 resizable 的窗口会按内容 fittingSize 定位，多屏拔插后可能落在屏外 → 每次打开拉回主屏（原点 0,0 那块）中央
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        if let win = windowController?.window, let screen = mainScreen {
            let f = screen.visibleFrame
            var r = win.frame
            r.origin.x = f.midX - r.width / 2
            r.origin.y = f.midY - r.height / 2
            win.setFrame(r, display: true)
            appLog("panel: open frame=\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))")
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 菜单开关变化 / 角色切换 / 引擎通知都会走到这里；不可见时跳过（open 会强制刷）
    func refresh(forceRebuild: Bool = false) {
        guard let win = windowController?.window, forceRebuild || win.isVisible else { return }
        if forceRebuild || builtRole != S.role {
            builtRole = S.role
            rebuildRows()
        }
        for (_, row) in rowMap { row.update() }
    }

    // MARK: 构建
    private func rebuildRows() {
        rowMap.removeAll()
        bodyStack.arrangedSubviews.forEach { bodyStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let features = builtRole == "slave" ? PanelController.slaveFeatures : PanelController.masterFeatures
        // 一张 NSGridView 装下表头 + 所有功能行，列宽自动对齐，不再手工摆约束
        var rows: [[NSView]] = [[
            headerLabel("启用"), headerLabel("功能"), headerLabel("生效状态"),
            headerLabel("仅在时段生效"), headerLabel("开始"), headerLabel(""), headerLabel("结束"),
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
        bodyStack.addArrangedSubview(grid)
        bodyStack.addArrangedSubview(headerLabel(
            builtRole == "slave"
            ? "当前角色：从动 —— 以上为本机被动看护相关功能"
            : "当前角色：主控 —— 以上为驱动远端相关功能；切换角色后此处自动跟随"))
    }

    private func headerLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "ScreenLink 控制面板"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        windowController = NSWindowController(window: win)

        // 直接用窗口自带的 contentView（它由窗口管 frame）；自建 view 当 contentView
        // 又关 translatesAutoresizingMask 会导致整棵约束树位置不受管
        let content = win.contentView!
        let title = NSTextField(labelWithString: "ScreenLink 控制面板")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString:
            "每个功能可单独开关，并可限定生效时间段（时段外视同关闭）。改动立即生效，无需重启。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 14
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bodyStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            bodyStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bodyStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口只隐藏不销毁，下次打开直接复用
    }

    // MARK: 行内控件事件（由 FeatureRow 转发）
    fileprivate func featureToggled(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        appLog("switch(panel): \(key)=\(on) win=\(S.window(key).isEmpty ? "全天" : S.window(key))")
        Engine.shared.applySettingChange()
        rowMap[key]?.update()
    }

    fileprivate func windowToggled(_ key: String, _ on: Bool) {
        let v = on ? (rowMap[key]?.defaultWindow() ?? "22:00-07:00") : ""
        S.setWindow(key, v)
        appLog("window(panel): \(key)=\(v.isEmpty ? "全天" : v)")
        Engine.shared.applySettingChange(keepAliveSync: false)
        rowMap[key]?.update()
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
        let hasWin = parseWindow(w) != nil
        winCheck.state = hasWin ? .on : .off

        let inWin = S.inWindow(key)
        if !on { stateLabel.stringValue = "已关闭" }
        else if !hasWin { stateLabel.stringValue = "全天生效" }
        else { stateLabel.stringValue = inWin ? "生效中 · \(w)" : "未生效 · \(w)" }
        stateLabel.textColor = (on && inWin) ? .systemGreen : .secondaryLabelColor

        if hasWin, let win = parseWindow(w) {
            setPicker(startPick, minuteOfDay: win.start)
            setPicker(endPick, minuteOfDay: win.end)
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

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
