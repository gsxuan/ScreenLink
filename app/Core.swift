// Core.swift — ScreenLink 引擎（主控 / 从动）
//
// 从 sscreenlink v2 daemon 抽出来的同一套逻辑，改成可被 App 常驻驱动。
// 主控：监听本机屏保/锁屏/显示器休眠 → 经 SSH 操作远端状态文件
// 从动：监听状态文件 → 拉起/收起屏保引擎 + 保活 caffeinate
//
// 已踩过的坑（别改回去）：
//  - 远端 `open -a ScreenSaverEngine.app` 会秒退并触发不可逆 loginwindow 锁
//  - 主控不要 SSH 远端执行二进制（非 GUI 会话被 AMFI 按路径 SIGKILL，rc=255）
//    → 只 SSH 跑 shell 的 touch/rm，osascript 交给远端已授权的从动进程
//  - 从动的事件源必须强引用持有，否则出作用域即 cancel、永不触发
import Foundation
import CoreGraphics

// MARK: - 路径
let HOME_DIR      = NSHomeDirectory()
let DIR_PATH      = HOME_DIR + "/sscreenlink"
let STATE_SAVER   = DIR_PATH + "/saver-wanted"
let STATE_KEEP    = DIR_PATH + "/keep-awake"
let STATE_FORCE   = DIR_PATH + "/force-hold"     // 主控下发：本机屏保期间远端必须保持屏保
let FILE_HB       = DIR_PATH + "/heartbeat"
let FILE_ROLE     = DIR_PATH + "/role"
let PID_CAFFEINE  = DIR_PATH + "/caffeinate.pid"
let APP_LOG_PATH  = "/tmp/screenlink-app.log"
let HEARTBEAT_TTL: TimeInterval = 120

// MARK: - 日志
func appLog(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] " + msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: APP_LOG_PATH) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: APP_LOG_PATH), options: .atomic)
    }
}

// MARK: - 进程工具
@discardableResult
func sh(_ argv: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func shOut(_ argv: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 完全非阻塞地跑一个命令（从动事件队列专用，绝不能被 osascript 卡住）
func runDetached(_ path: String, _ args: [String], _ done: ((Int32) -> Void)? = nil) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    if let done = done { p.terminationHandler = { done($0.terminationStatus) } }
    do { try p.run() } catch { appLog("runDetached failed: \(path) \(error)") }
}

// MARK: - 文件工具
func touchFile(_ path: String) { FileManager.default.createFile(atPath: path, contents: Data()) }
func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
func removeFile(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

func fileAge(_ path: String) -> TimeInterval? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path),
          let m = a[.modificationDate] as? Date else { return nil }
    return Date().timeIntervalSince(m)
}

func isFresh(_ path: String, _ ttl: TimeInterval) -> Bool {
    guard let t = fileAge(path) else { return false }
    return t < ttl
}

func ensureDir() {
    try? FileManager.default.createDirectory(atPath: DIR_PATH, withIntermediateDirectories: true)
}

// MARK: - 系统状态
func hidIdleSeconds() -> Double {
    let out = shOut(["/usr/sbin/ioreg", "-c", "IOHIDSystem"])
    guard let re = try? NSRegularExpression(pattern: "\"HIDIdleTime\" = (\\d+)") else { return .infinity }
    let ns = out as NSString
    var best = Double.infinity
    for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges >= 2, let v = Double(ns.substring(with: m.range(at: 1))) {
            best = min(best, v / 1e9)
        }
    }
    return best
}

func screensaverRunning() -> Bool {
    // 现代 macOS 上 ScreenSaverEngine 只是短命启动器，session agent 才持有实际屏保。
    // 先做廉价进程判断，再以 loginwindow 的屏保运行态为权威。
    if sh(["/usr/bin/pgrep", "-x", "ScreenSaverEngine"]) == 0 { return true }
    let out = shOut(["/usr/bin/osascript", "-e",
                     "tell application \"System Events\" to get running of screen saver preferences"])
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return out == "true"
}

/// 仅进程判断（主控专用）：不碰 osascript。
/// 关键：新 App 首次调 osascript 会等 TCC 授权弹窗并阻塞主线程，主控绝不能用它。
func saverProcessAlive() -> Bool {
    sh(["/usr/bin/pgrep", "-x", "ScreenSaverEngine"]) == 0
}

func sessionLocked() -> Bool {
    let out = shOut(["/usr/sbin/ioreg", "-n", "Root", "-d1", "-a"])
    guard let re = try? NSRegularExpression(pattern: "CGSSessionScreenIsLocked</key>\\s*<true/>") else { return false }
    let ns = out as NSString
    return re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) != nil
}

func displayAsleep() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
}

func presenceThreshold() -> Double {
    let idle = shOut(["/usr/bin/defaults", "-currentHost", "read", "com.apple.screensaver", "idleTime"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let v = Double(idle), v > 0 { return min(max(v, 60), 3600) }
    let pm = shOut(["/usr/bin/pmset", "-g"])
    if let re = try? NSRegularExpression(pattern: "displaysleep\\s+(\\d+)"),
       let m = re.firstMatch(in: pm, range: NSRange(pm.startIndex..., in: pm)),
       let mins = Double((pm as NSString).substring(with: m.range(at: 1))), mins > 0 {
        return min(max(mins * 60, 60), 3600)
    }
    return 600
}

// MARK: - 屏保引擎
func spawnSaverAsync() {
    runDetached("/usr/bin/osascript",
                ["-e", "tell application \"System Events\" to start current screen saver"]) { rc in
        appLog(rc == 0 ? "saver started" : "saver start failed rc=\(rc)")
    }
}

func collectSaverAsync() {
    // 必须经 System Events 停（才会发出解锁通知）；pkill 只作兜底
    runDetached("/usr/bin/osascript",
                ["-e", "tell application \"System Events\" to stop current screen saver"]) { _ in
        runDetached("/usr/bin/pkill", ["-x", "ScreenSaverEngine"])
    }
}

func stopSaverSync() {
    _ = sh(["/usr/bin/osascript", "-e", "tell application \"System Events\" to stop current screen saver"])
    sh(["/usr/bin/pkill", "-x", "ScreenSaverEngine"])
}

func wakeDisplayAsync() {
    runDetached("/usr/bin/caffeinate", ["-u", "-t", "1"])
}

// MARK: - 保活（caffeinate）
func caffeinatePid() -> pid_t? {
    guard let s = try? String(contentsOfFile: PID_CAFFEINE, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = Int32(s), pid > 0 else { return nil }
    return pid
}

func caffeinateAlive(_ pid: pid_t) -> Bool {
    shOut(["/bin/ps", "-p", "\(pid)", "-o", "comm="]).contains("caffeinate")
}

func ensureCaffeinate() {
    // 主控离线 / 断网 → 心跳过期 → 自动释放，远端恢复正常屏保行为
    if fileExists(STATE_KEEP) && !isFresh(FILE_HB, HEARTBEAT_TTL) {
        removeFile(STATE_KEEP)
        appLog("keep-awake: heartbeat expired -> released")
    }
    let want = fileExists(STATE_KEEP)
    if let pid = caffeinatePid() {
        if caffeinateAlive(pid) {
            if !want {
                kill(pid, SIGTERM)
                removeFile(PID_CAFFEINE)
                appLog("keep-awake off (pid \(pid))")
            }
            return
        }
        removeFile(PID_CAFFEINE)
    }
    guard want else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    p.arguments = ["-d", "-i", "-s"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        try? "\(p.processIdentifier)".write(toFile: PID_CAFFEINE, atomically: true, encoding: .utf8)
        appLog("keep-awake on (pid \(p.processIdentifier))")
    } catch { appLog("caffeinate spawn failed: \(error)") }
}

// MARK: - 主控 → 从动
func sshShell(_ peer: String, _ cmd: String) {
    func attempt(_ extra: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                       "-o", "StrictHostKeyChecking=accept-new"] + extra + [peer, cmd]
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do { try p.run() } catch { appLog("ssh spawn failed: \(error)"); return -1 }
        p.waitUntilExit()
        let rc = p.terminationStatus
        if rc != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            appLog("ssh \(peer) [\(cmd)] -> rc=\(rc) \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return rc
    }
    // 首选复用连接；失败后退化为独立连接重试一次
    var rc = attempt(["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/screenlink-ssh-%r@%h:%p",
                      "-o", "ControlPersist=30", "-o", "GSSAPIAuthentication=no"])
    if rc != 0 {
        rc = attempt([])
    }
}

// MARK: - 设置
enum S {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "enabled": true,
            "role": "master",
            "peer": "10.1.1.2",
            "syncEnter": true,
            "syncExit": true,
            "lockAsSaver": true,
            "keepAwake": true,
            "holdRemote": true,
            "forceHold": true,
            "wakeDisplay": true,
        ])
    }
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }
    static var role: String {
        get { UserDefaults.standard.string(forKey: "role") ?? "master" }
        set { UserDefaults.standard.set(newValue, forKey: "role") }
    }
    static var peer: String {
        get { UserDefaults.standard.string(forKey: "peer") ?? "10.1.1.2" }
        set { UserDefaults.standard.set(newValue, forKey: "peer") }
    }
    static var syncEnter: Bool {
        get { UserDefaults.standard.bool(forKey: "syncEnter") }
        set { UserDefaults.standard.set(newValue, forKey: "syncEnter") }
    }
    static var syncExit: Bool {
        get { UserDefaults.standard.bool(forKey: "syncExit") }
        set { UserDefaults.standard.set(newValue, forKey: "syncExit") }
    }
    static var lockAsSaver: Bool {
        get { UserDefaults.standard.bool(forKey: "lockAsSaver") }
        set { UserDefaults.standard.set(newValue, forKey: "lockAsSaver") }
    }
    static var keepAwake: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAwake") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAwake") }
    }
    static var forceHold: Bool {
        get { UserDefaults.standard.bool(forKey: "forceHold") }
        set { UserDefaults.standard.set(newValue, forKey: "forceHold") }
    }
    /// 主控下发：本机进屏保时，强制远端保持屏保（被真实输入划掉也立刻拉回）
    static var holdRemote: Bool {
        get { UserDefaults.standard.bool(forKey: "holdRemote") }
        set { UserDefaults.standard.set(newValue, forKey: "holdRemote") }
    }
    static var wakeDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "wakeDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "wakeDisplay") }
    }
}

// MARK: - 引擎
final class Engine {
    static let shared = Engine()

    private(set) var mode: String = ""
    private(set) var localActive = false
    private(set) var lastRemoteSync: Date?
    private(set) var lastError: String?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var watchSrc: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var tick = 0
    private var lastSynced: Bool?
    private var lastAsleep: Bool?
    private var lastWant: Bool?
    private var lastSpawn = Date.distantPast
    private var lastForcedSpawn = Date.distantPast
    private var healthInFlight = false

    /// UI 刷新回调（主线程）
    var onChange: (() -> Void)?

    private func notify() {
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { self.onChange?() } }
    }

    // MARK: 生命周期
    func restart() {
        stop()
        ensureDir()
        guard S.enabled else {
            mode = ""
            try? "disabled".write(toFile: FILE_ROLE, atomically: true, encoding: .utf8)
            appLog("engine: disabled by switch")
            // 关闭时尽力收回两端，避免残留在屏保
            removeFile(STATE_SAVER)
            stopSaverSync()
            removeFile(STATE_KEEP)
            notify()
            return
        }
        let role = S.role
        try? role.write(toFile: FILE_ROLE, atomically: true, encoding: .utf8)
        mode = role
        if role == "slave" { startSlave() } else { startMaster() }
        notify()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let dnc = DistributedNotificationCenter.default()
        for o in observers { dnc.removeObserver(o) }
        observers.removeAll()
        watchSrc?.cancel()
        watchSrc = nil
        if watchFD >= 0 { close(watchFD); watchFD = -1 }
        lastSynced = nil
        lastWant = nil
        lastAsleep = nil
        tick = 0
    }

    /// 开关变化后立即生效（不重启引擎）：主控重发一次当前目标态 + 保活态
    func applySettingChange() {
        guard S.enabled, mode == "master" else { return }
        lastSynced = nil
        syncTarget()
        masterKeepAwakeTick(peer: S.peer)
    }

    // MARK: 主控
    private func startMaster() {
        let peer = S.peer
        appLog("MASTER start peer=\(peer) pid=\(ProcessInfo.processInfo.processIdentifier)")

        lastAsleep = displayAsleep()
        localActive = saverProcessAlive() || lastAsleep! || sessionLocked()
        lastSynced = nil          // 强制首次对齐（同时清理远端残留意图）
        syncTarget()

        let dnc = DistributedNotificationCenter.default()
        // 进屏保
        for n in ["com.apple.screensaver.didstart", "com.apple.screenIsLocked",
                  "com.apple.sessionagent.screenIsLocked"] {
            let isLock = n.contains("Locked")
            observers.append(dnc.addObserver(forName: NSNotification.Name(n), object: nil, queue: nil) { [weak self] _ in
                guard let self = self else { return }
                if isLock && !S.lockAsSaver { return }   // 锁屏同步可单独关掉
                self.setActive(true)
            })
        }
        // 退屏保
        for n in ["com.apple.screensaver.didstop", "com.apple.screenIsUnlocked",
                  "com.apple.sessionagent.screenIsUnlocked"] {
            observers.append(dnc.addObserver(forName: NSNotification.Name(n), object: nil, queue: nil) { [weak self] _ in
                self?.setActive(false)
            })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick += 1
            if self.tick % 2 == 0 {
                let asleep = displayAsleep()
                if asleep != self.lastAsleep {
                    self.lastAsleep = asleep
                    self.setActive(asleep)
                }
            }
            guard self.tick % 20 == 1 else { return }
            self.masterKeepAwakeTick(peer: peer)
        }
    }

    private func masterKeepAwakeTick(peer: String) {
        // 兜底重发：本机仍在屏保且开了强制保持 → 每 20s 重新断言远端意图
        // （防远端 App 重启/文件被误删导致的失联）
        if localActive && S.holdRemote && S.syncEnter {
            sshShell(peer, "touch '\(STATE_SAVER)' '\(STATE_FORCE)'")
        }
        guard S.keepAwake else {
            // 开关关掉后要确保远端释放保活，否则远端再也不会自己进屏保
            sshShell(peer, "rm -f '\(STATE_KEEP)' '\(FILE_HB)'")
            return
        }
        // 本机是否「有人在场」：只看 HID 空闲时间（不调 osascript，避免 TCC 阻塞）
        let present = hidIdleSeconds() < presenceThreshold()
        sshShell(peer, present
                 ? "touch '\(STATE_KEEP)' '\(FILE_HB)'"
                 : "rm -f '\(STATE_KEEP)' '\(FILE_HB)'")
        if present && !localActive { setActive(false) }
    }

    private func setActive(_ v: Bool) {
        localActive = v
        syncTarget()
        notify()
    }

    private func syncTarget() {
        let peer = S.peer
        guard localActive != lastSynced else { return }
        if localActive {
            guard S.syncEnter else { lastSynced = localActive; return }
            // holdRemote：本机屏保期间要求远端「必须保持屏保」，从动侧会无条件复拉
            let hold = S.holdRemote ? "touch '\(STATE_FORCE)'" : "rm -f '\(STATE_FORCE)'"
            appLog("sync: local active -> \(peer) enter (hold=\(S.holdRemote))")
            sshShell(peer, "touch '\(STATE_SAVER)'; \(hold)")
        } else {
            guard S.syncExit else { lastSynced = localActive; return }
            appLog("sync: local inactive -> \(peer) exit")
            // 一次往返：置保活（若开）+ 清屏保意图 + 撤销强制保持
            let keep = S.keepAwake ? "touch '\(STATE_KEEP)' '\(FILE_HB)'; " : ""
            sshShell(peer, "\(keep)rm -f '\(STATE_SAVER)' '\(STATE_FORCE)'")
        }
        lastSynced = localActive
        lastRemoteSync = Date()
    }

    // MARK: 从动
    private func startSlave() {
        appLog("SLAVE start (file-watch + health guard)")
        let q = DispatchQueue(label: "screenlink.slave")
        lastWant = nil
        lastSpawn = Date.distantPast
        tick = 0
        healthInFlight = false

        func reconcile() {
            let want = fileExists(STATE_SAVER)
            guard want != lastWant else { return }
            if want {
                lastSpawn = Date()
                appLog("slave: saver-wanted -> spawn")
                spawnSaverAsync()
            } else {
                appLog("slave: saver-wanted cleared -> collect")
                collectSaverAsync()
                if S.wakeDisplay { wakeDisplayAsync() }
            }
            lastWant = want
            notify()
        }

        let fd = open(DIR_PATH, O_EVTONLY)
        if fd >= 0 {
            watchFD = fd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: q)
            src.setEventHandler { reconcile() }
            src.resume()
            watchSrc = src          // 必须强持有，否则出作用域即被 ARC 取消
        } else {
            appLog("slave: WARN cannot watch \(DIR_PATH); fallback to 1s poll")
        }

        // 关键：屏保被真实输入（鼠标/键盘/通用控制）划掉的瞬间立即拉回，
        // 不等轮询——否则远端会裸露出桌面好几秒。
        let dnc = DistributedNotificationCenter.default()
        for n in ["com.apple.screensaver.didstop", "com.apple.screenIsUnlocked",
                  "com.apple.sessionagent.screenIsUnlocked"] {
            observers.append(dnc.addObserver(forName: NSNotification.Name(n), object: nil, queue: nil) { [weak self] _ in
                guard let self = self else { return }
                // master 主动收起时 saver-wanted 已被删除，这里自然跳过
                guard fileExists(STATE_SAVER) else { return }
                guard fileExists(STATE_FORCE) || S.forceHold else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastForcedSpawn) > 0.4 else { return }  // 防抖
                self.lastForcedSpawn = now
                self.lastSpawn = now
                appLog("slave: dismissed by input -> re-assert saver now")
                q.async { spawnSaverAsync() }
            })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick += 1
            q.async { reconcile() }
            // 强制保持：主控下发的 force-hold 优先，或本机开关开启
            // 意图存在但引擎被真实输入（UC/远程桌面）划掉 → 复拉
            let forced = fileExists(STATE_FORCE) || S.forceHold
            let masterForced = fileExists(STATE_FORCE)            // 强制期间每个 tick（1s）都查；本地开关只做 2s 一次，省 osascript
            if (masterForced || self.tick % 2 == 0) && forced && fileExists(STATE_SAVER) && !self.healthInFlight {
                self.healthInFlight = true
                DispatchQueue.global(qos: .utility).async {
                    let running = screensaverRunning()
                    q.async {
                        self.healthInFlight = false
                        if fileExists(STATE_SAVER) && !running && Date().timeIntervalSince(self.lastSpawn) > 1.2 {
                            self.lastSpawn = Date()
                            appLog("slave: force-hold respawn"
                                   + (fileExists(STATE_FORCE) ? " (master-forced)" : " (local)"))
                            spawnSaverAsync()
                        }
                    }
                }
            }
            if self.tick % 5 == 0 { ensureCaffeinate() }
        }
        q.async { reconcile() }
    }
}
