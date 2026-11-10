# ScreenLink

两台 Mac 的**屏保/锁屏联动**菜单栏应用：本机进入屏保，另一台同步进入；本机退出，另一台同步退出。

用一台 Mac 的锁屏动作，同时锁住整个桌面环境——适合「主力机 + 副屏/工作机」的双机摆法，离开座位时不用两台各按一次。

![菜单栏图标](docs/icon.png)

## 功能

**主控（master）** — 监听本机的屏保 / 锁屏 / 显示器休眠，实时下发给远端：

| 开关 | 说明 |
|---|---|
| 进入屏保时远端跟随 | 本机进屏保 → 远端同时进屏保 |
| 退出屏保时远端跟随 | 本机退屏保 → 远端自动退出 |
| 锁屏视同进入屏保 | 直接锁屏（不跑屏保）也触发远端进入 |
| 本机屏保时强制远端保持 | 远端屏保被鼠标/键盘/通用控制划掉时**立即拉回**，不裸露桌面 |
| 本机活跃时阻止远端进屏保 | 本机有人在用，远端不会自己睡进屏保 |

**从动（slave）** — 被动看护，不发任何主动连接：

| 开关 | 说明 |
|---|---|
| 强制保持本机屏保 | 屏保被划掉时自动恢复（主控下发时以主控为准） |
| 退出时唤醒远端显示器 | 退出屏保时把显示器叫醒 |

**其它**

- 菜单栏常驻图标，无 Dock 图标；顶部实时显示「本机状态 / 远端状态」
- **隐藏菜单栏图标**：菜单里选「隐藏菜单栏图标（后台继续运行）」，图标收起但联动照常工作；**再点一次 App（访达 / 启动台 / Spotlight）图标就回来**
- 一键测试远端连接、远端地址可改、登录时自动启动

## 延迟

事件驱动的实现，不做轮询：

| 动作 | 实测延迟 |
|---|---|
| 本机进屏保 → 远端出屏保 | ≈ 140–350 ms |
| 本机退屏保 → 远端收起 | ≈ 40–250 ms |
| 远端屏保被划掉 → 自动恢复 | ≈ 140–330 ms |

> 屏保被输入划掉时，系统必须销毁并重建屏保进程，这 ~0.15 s 是机制下限。若持续用「通用控制」推远端鼠标，会看到 0.3 s 级闪烁，属固有行为。

## 环境要求

- macOS 13 或更高（在 macOS 27 上开发验证）
- 两台 Mac 处于同一局域网，**双向免密 SSH** 可用（主控 → 从动）
- 从动端**不要开启「需要密码解锁」的强制锁屏**（`sysadminctl -screenLock status` 应为 `off`），否则远端只能进屏保、无法被程序化唤醒

## 安装

1. 从 [Releases](https://github.com/gsxuan/ScreenLink/releases/latest) 下载 `ScreenLink-<版本>.dmg`，双击挂载后把 ScreenLink 拖进窗口里的 `Applications` 快捷方式即装（也想用命令行就下 `ScreenLink-<版本>.zip`，解压后手动拖进 `/Applications`）
2. 两台机器都打开一次（首次会被 Gatekeeper 拦，右键 → 打开）
3. **主控端**：菜单 → 本机角色 → 主控；远端地址填另一台的内网 IP
4. **从动端**：菜单 → 本机角色 → 从动
5. 主控端菜单 → 测试远端连接，确认 SSH 免密可用

### 配置免密 SSH

```bash
# 在主控机上执行（把 IP 换成从动机的）
ssh-keygen -t ed25519 -C screenlink        # 已有密钥可跳过
ssh-copy-id think@10.1.1.2
ssh -o BatchMode=yes think@10.1.1.2 'echo OK'   # 应输出 OK，且不询问密码
```

### 系统授权（首次会弹窗）

- **从动端**：首次拉起屏保时会请求「系统事件」自动化权限 → 点**允许**。若误点拒绝，到 `系统设置 → 隐私与安全性 → 自动化` 里勾选 ScreenLink。
- **两端**：首次 SSH 出网会请求「本地网络」权限 → 点**允许**，否则连接会被拒（表现为 `rc=255`，日志里能看到）。

## 从源码构建

```bash
git clone https://github.com/gsxuan/ScreenLink.git
cd ScreenLink
./build.sh                       # 产出 ScreenLink.app，并打包 dist/ScreenLink-<版本>.dmg 与 .zip
cp -R ScreenLink.app /Applications/
```

`build.sh` 用 `swiftc` 直接编译，无第三方依赖：编译主程序 → 代码绘制图标 → 生成 `.icns` → 组装 bundle → ad-hoc 签名 → 打包 DMG/ZIP。

## 打包与发布

仓库**不跟踪构建产物**（`ScreenLink.app/`、`build/`、`dist/` 都在 `.gitignore` 里），二进制只通过 [Releases](https://github.com/gsxuan/ScreenLink/releases) 分发。

一次 `./build.sh` 就会在 `dist/` 产出两个同名不同格式的安装包（版本号自动取自 `Info.plist` 的 `CFBundleShortVersionString`）：

| 产物 | 生成方式 | 用途 |
|---|---|---|
| `ScreenLink-<版本>.dmg` | `hdiutil create -format UDZO`，内含 App + `/Applications` 快捷链接 | 主安装包，双击挂载拖拽即装 |
| `ScreenLink-<版本>.zip` | `ditto -c -k --keepParent`（保留 bundle 结构，不产生 `__MACOSX`） | 备用，适合 `curl`/命令行部署 |

发布步骤：打好 `vX.Y` 标签推到远端 → 在 Releases 建同名 release → 上传 `dist/` 下的 `.dmg` 与 `.zip`（资产名带版本号，README 安装说明按 `ScreenLink-<版本>.dmg` 写）。App 为 ad-hoc 签名、未做公证，首次打开需右键 → 打开。

## 工作原理

```
主控 Mac                                    从动 Mac
────────                                    ────────
分布式通知 / CGDisplayIsAsleep
        │
        ├─ SSH: touch  ~/sscreenlink/saver-wanted   ← 状态文件
        ├─ SSH: rm    ~/sscreenlink/saver-wanted
        └─ SSH: touch/rm  ~/sscreenlink/force-hold
                                                │
                                  目录级文件系统事件监听（FSEvents）
                                                │
                                    osascript → System Events
                                    start/stop current screen saver
```

几个关键设计：

- **只用状态文件传递意图**，不通过 SSH 远端执行二进制。远端可执行文件在非 GUI 会话里会被 AMFI 按路径 SIGKILL，走文件则完全绕开这个坑（也避开了 TCC 按路径授权的差异）。
- **从动端事件驱动**：监听 `~/sscreenlink` 目录的写入事件，`saver-wanted` 一变就响应，不做定时轮询。
- **非阻塞执行**：拉起/收起/唤醒都用 fire-and-forget，事件队列不会被 `osascript`（~0.1 s）或 `caffeinate -u -t 1` 堵住。
- **主控端零 osascript**：新装的 App 第一次控制「系统事件」会同步等待授权弹窗，若在主控路径调用会把主线程锁死、通知全收不到。主控只用 `pgrep` / `ioreg` / `CGDisplayIsAsleep` 判断状态。
- **单实例 + 重新打开即恢复图标**：靠 `/tmp/screenlink-app.lock` 的 `flock`；第二个实例启动时不抢占，而是发一个分布式通知让前台实例把菜单栏图标显示出来，然后自己退出。

## 配置与数据

| 路径 | 内容 |
|---|---|
| `~/sscreenlink/` | 状态文件（`saver-wanted` / `force-hold` / `keep-awake` / `role`） |
| `~/sscreenlink-app.log` → `/tmp/screenlink-app.log` | 运行日志，含 SSH 失败的 stderr 全文 |
| `~/Library/LaunchAgents/com.think.screenlink.app.plist` | 勾选「登录时启动」后生成 |
| `defaults read com.think.screenlink.app` | 所有开关的当前值 |

## 常见问题

**远端没反应 / 日志里 `rc=255`**
先手动跑一次 `ssh -o BatchMode=yes <peer> 'echo OK'`。失败多为：未配置免密、从动端「远程登录」未开、或 App 的「本地网络」权限未授权。

**远端进了屏保但退不出来**
从动端开启了「需要密码解锁」的强制锁屏，程序化唤醒会被拦。用 `sysadminctl -screenLock status` 确认。

**菜单栏图标不见了**
联动仍在后台运行。再点一次 ScreenLink（访达 / 启动台 / Spotlight）图标就回来；也可以在终端 `open -a ScreenLink`。

**两台机器都设成了从动**
没有任何一台会下发，联动不生效。至少一台要是主控。

## 许可证

[Apache License 2.0](LICENSE)
