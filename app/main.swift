// main.swift — ScreenLink 菜单栏应用
//
// 单实例常驻菜单栏（LSUIElement），所有能力都可单独开关：
//   启用联动 / 进屏保同步 / 退屏保同步 / 锁屏同步 / 阻止远端屏保 / 强制保持 / 唤醒显示器
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
    var winItems: [String: NSMenuItem] = [:]       // key -> 生效时间菜单项
    var winTitles: [String: String] = [:]          // key -> 开关显示名
    var roleItems: [String: NSMenuItem] = [:]
    var loginItem: NSMenuItem!
    var testItem: NSMenuItem!
    var masterOnly: [NSMenuItem] = []
    var slaveOnly: [NSMenuItem] = []

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
        addWindowSection(to: syncMenu, keys: [
            ("syncEnter", "进屏保跟随"),
            ("holdRemote", "强制远端保持"),
            ("syncExit", "退屏保跟随"),
            ("lockAsSaver", "锁屏视同屏保"),
            ("keepAwake", "阻止远端屏保"),
        ])
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
        addWindowSection(to: slaveMenu, keys: [
            ("forceHold", "强制保持屏保"),
            ("wakeDisplay", "退出唤醒显示器"),
        ])
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

    /// 在子菜单里追加「生效时间」区块：每个开关一项，点击弹框配时间段
    func addWindowSection(to target: NSMenu, keys: [(key: String, title: String)]) {
        target.addItem(.separator())
        let head = NSMenuItem(title: "生效时间（时段内才启用）", action: nil, keyEquivalent: "")
        head.isEnabled = false
        target.addItem(head)
        for (key, title) in keys {
            winTitles[key] = title
            let it = NSMenuItem(title: title, action: #selector(editWindow(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.image = symbol("clock")
            target.addItem(it)
            winItems[key] = it
        }
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
        for (key, item) in winItems {
            let w = S.window(key)
            let win = w.isEmpty ? "全天" : w.replacingOccurrences(of: "-", with: "–")
            item.title = "\(winTitles[key] ?? key)：\(win)"
            item.isEnabled = S.enabled
        }
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

    @objc func editWindow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let cur = S.window(key)
        let parts = cur.isEmpty ? [] : cur.split(separator: "-", maxSplits: 1).map(String.init)

        let alert = NSAlert()
        alert.messageText = "生效时间 · \(winTitles[key] ?? key)"
        alert.informativeText = "仅在时间段内启用该功能，其余时间视同关闭。\n格式 HH:mm（如 09:00）；结束早于开始 = 跨午夜（如 22:00–07:00）。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let check = NSButton(checkboxWithTitle: "仅在以下时间段生效", target: nil, action: nil)
        check.state = cur.isEmpty ? .off : .on
        let startF = NSTextField(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
        startF.stringValue = parts.count == 2 ? parts[0] : "22:00"
        startF.placeholderString = "HH:mm"
        startF.alignment = .center
        let endF = NSTextField(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
        endF.stringValue = parts.count == 2 ? parts[1] : "07:00"
        endF.placeholderString = "HH:mm"
        endF.alignment = .center

        let row = NSStackView(views: [startF, NSTextField(labelWithString: "至"), endF])
        row.orientation = .horizontal
        row.spacing = 8
        let box = NSStackView(views: [check, row])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 10
        box.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        alert.accessoryView = box
        alert.window.initialFirstResponder = check

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var v = ""
        if check.state == .on {
            let a = startF.stringValue.trimmingCharacters(in: .whitespaces)
            let b = endF.stringValue.trimmingCharacters(in: .whitespaces)
            guard parseTimeOfDay(a) != nil, parseTimeOfDay(b) != nil else {
                let bad = NSAlert()
                bad.messageText = "时间格式不正确"
                bad.informativeText = "请用 HH:mm 格式（如 09:00、22:30），时 0–23、分 0–59。"
                bad.runModal()
                return
            }
            let am = parseTimeOfDay(a)!
            let bm = parseTimeOfDay(b)!
            guard am != bm else {
                let bad = NSAlert()
                bad.messageText = "开始与结束不能相同"
                bad.informativeText = "相同时间没有意义；想全天生效请取消勾选「仅在以下时间段生效」。"
                bad.runModal()
                return
            }
            v = "\(a)-\(b)"
        }
        S.setWindow(key, v)
        appLog("window: \(key)=\(v.isEmpty ? "全天" : v)")
        Engine.shared.applySettingChange(keepAliveSync: false)
        refresh()
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

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
