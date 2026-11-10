<div align="center">

<img src="docs/icon.png" width="88" height="88" alt="ScreenLink" />

# ScreenLink

**两台 Mac 的屏保 / 锁屏联动菜单栏应用。** 本机进屏保，另一台同步进；本机退出，另一台同步退出。

用一台 Mac 的锁屏动作锁住整个双机桌面——适合「主力机 + 副屏/工作机」，离开座位不用两台各按一次。

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple&logoColor=white)](#环境要求)
[![Release](https://img.shields.io/github/v/release/gsxuan/ScreenLink?label=release&color=green)](https://github.com/gsxuan/ScreenLink/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gsxuan/ScreenLink/total?label=downloads&color=brightgreen)](https://github.com/gsxuan/ScreenLink/releases)

</div>

---

## 快速开始

从 [Releases](https://github.com/gsxuan/ScreenLink/releases/latest) 下载 `ScreenLink-<版本>.dmg`，双击挂载后把 ScreenLink 拖进窗口里的 `Applications` 快捷方式，两台机器各打开一次即可。首次打开若被 Gatekeeper 拦，右键 → 打开。

装好后：**一台设为「主控」并填另一台的内网 IP，另一台设为「从动」**，主控端菜单里点「测试远端连接」确认免密 SSH 可用，联动即生效。

想一条命令搞定安装与配置，见下方 [Agent 安装与配置](#agent-安装与配置)。

## 安装

1. 从 [Releases](https://github.com/gsxuan/ScreenLink/releases/latest) 下载 `ScreenLink-<版本>.dmg`（或 `ScreenLink-<版本>.zip`，解压后手动拖进 `/Applications`）
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

## 环境要求

- macOS 13 或更高（在 macOS 27 上开发验证，Apple Silicon / arm64）
- 两台 Mac 处于同一局域网，**双向免密 SSH** 可用（主控 → 从动）
- 从动端**不要开启「需要密码解锁」的强制锁屏**（`sysadminctl -screenLock status` 应为 `off`），否则远端只能进屏保、无法被程序化唤醒

## Agent 安装与配置

把下面这句话连同代码块交给任意 Coding Agent（Claude Code / Codex / coding-agent skill），即可自动完成下载、安装与配置：

> 用 Releases 里最新的 `ScreenLink-<版本>.dmg` 把 ScreenLink 装到 `/Applications`，按给定参数用 `defaults write com.think.screenlink.app` 写好角色与远端地址，再 `open -a ScreenLink` 启动；主控端启动前先确认对从动机的免密 SSH 已可用。

```bash
# 主控示例：把 peer 换成从动机的内网 IP（curl 下载不带隔离属性，通常无需右键绕过 Gatekeeper）
VER=3.5
curl -fL -o /tmp/ScreenLink.dmg "https://github.com/gsxuan/ScreenLink/releases/download/v${VER}/ScreenLink-${VER}.dmg"
hdiutil attach /tmp/ScreenLink.dmg -nobrowse -mountpoint /Volumes/ScreenLink
cp -R /Volumes/ScreenLink/ScreenLink.app /Applications/
hdiutil detach /Volumes/ScreenLink
ssh -o BatchMode=yes think@10.1.1.2 'echo OK'          # 免密前置校验，失败先 ssh-copy-id
defaults write com.think.screenlink.app enabled -bool true
defaults write com.think.screenlink.app role    -string master
defaults write com.think.screenlink.app peer    -string 10.1.1.2
# 可选：给单个开关配生效时间段（HH:mm-HH:mm，结束早于开始 = 跨午夜；不配 = 全天）
defaults write com.think.screenlink.app holdRemoteWin -string '22:00-07:00'   # 强制远端保持仅夜间生效
defaults write com.think.screenlink.app keepAwakeWin  -string '09:00-18:00'   # 阻止远端屏保仅工作时间生效
open -a ScreenLink
```

从动机把 `role` 改成 `slave`、`peer` 留空即可。相关 skills：**coding-agent / claude-code / codex** 负责执行上面的安装配置；跨机免密与环境准备可交给 **ssh** skill。

## 特性

- **事件驱动、低延迟**——基于分布式通知与 FSEvents，不做轮询，进/出屏保同步 ≈ 140–350 ms
- **主控 / 从动**双角色，逐项能力可单独开关（进屏保跟随、退屏保跟随、锁屏视同屏保、强制远端保持、活跃时阻止远端睡屏保……）
- **控制面板窗口**：两台 Mac 的统一管理台 —— 状态总览（本机/远端实时状态、心跳、上次同步）、基础设置（联动/角色/远端地址/登录项/测试连接）、功能开关与生效时间窗表格、两机设置逐项对照 + 一键互相同步（SSH 推送，远端自动重载）
- **被划掉也能拉回**——远端屏保被鼠标/键盘/通用控制打断时立即复拉，不裸露桌面
- **菜单栏常驻、无 Dock 图标**，可一键隐藏图标后台运行；再点一次 App 图标即回来
- 零第三方依赖：`swiftc` 直接编译，代码绘制图标，产出 DMG/ZIP

## 功能

**主控（master）** — 监听本机的屏保 / 锁屏 / 显示器休眠，实时下发给远端：

| 开关 | 说明 |
|---|---|
| 进入屏保时远端跟随 | 本机进屏保 → 远端同时进屏保 |
| 退出屏保时远端跟随 | 本机退屏保 → 远端自动退出 |
| 锁屏视同进入屏保 | 直接锁屏（不跑屏保）也触发远端进入 |
| 本机屏保时强制远端保持 | 远端屏保被鼠标/键盘/通用控制划掉时**立即拉回**，不裸露桌面；可配生效时间窗，窗口外远端屏保可正常划掉 |
| 本机活跃时阻止远端进屏保 | 本机有人在用，远端不会自己睡进屏保 |

**从动（slave）** — 被动看护，不发任何主动连接：

| 开关 | 说明 |
|---|---|
| 强制保持本机屏保 | 屏保被划掉时自动恢复；主控在线同步期间以主控的「本机屏保时强制远端保持」（含其时间窗）为准，本开关仅在主控离线/失联时兜底 |
| 退出时唤醒远端显示器 | 退出屏保时把显示器叫醒 |

**其它**

- 菜单栏常驻图标，无 Dock 图标；顶部实时显示「本机状态 / 远端状态」
- **控制面板窗口**：菜单里选「控制面板…」（或按 ⌘,），四个区块：
  1. **状态总览**：本机 / 远端实时状态（屏保、强制保持、保活、心跳龄期、远端角色），面板打开期间 5s 自动刷新
  2. **基础设置**：启用联动、本机角色、远端地址、登录时启动、测试连接
  3. **功能开关与生效时间窗**：每功能一行（开关 / 生效状态 / 仅在时段生效 / 时:分选择器），时间段格式 `HH:mm-HH:mm`，结束早于开始视为跨午夜，默认全天；窗口外视同关闭，改动立即生效
  4. **两机设置统一**：本机 vs 远端逐项对照（不一致标红 ✗），「远端同本机」经 SSH 写入设置并 touch `reload-settings` 通知远端自动重载（角色自动设为互补、peer 自动互指）；「本机同远端」反向拉取功能开关与时间窗（角色/地址不拉取，避免互指关系被破坏）
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

## 从源码构建

```bash
git clone https://github.com/gsxuan/ScreenLink.git
cd ScreenLink
./build.sh                       # 产出 ScreenLink.app，并打包 dist/ScreenLink-<版本>.dmg 与 .zip
cp -R ScreenLink.app /Applications/
```

`build.sh` 用 `swiftc` 直接编译，无第三方依赖：编译主程序 → 代码绘制图标 → 生成 `.icns` → 组装 bundle → ad-hoc 签名 → 打包 DMG/ZIP。

## 项目结构

```
ScreenLink/
├── app/                # 应用源码
│   ├── main.swift       # 菜单栏 UI（NSStatusItem / 菜单 / 弹框）
│   ├── Core.swift       # 联动引擎（主控下发 / 从动看护 / 状态文件）
│   ├── Panel.swift      # 控制面板窗口（状态 / 基础设置 / 开关表 / 两机统一）
│   └── Info.plist       # bundle 描述（LSUIElement、权限用途串、版本号）
├── icon/main.swift      # 代码绘制应用图标（生成 icon-1024.png）
├── docs/icon.png        # README 展示用图标
├── build.sh             # 一键编译 + 打包 DMG/ZIP
├── LICENSE              # Apache License 2.0
└── README.md
```

## 打包与发布

仓库**不跟踪构建产物**（`ScreenLink.app/`、`build/`、`dist/` 都在 `.gitignore` 里），二进制只通过 [Releases](https://github.com/gsxuan/ScreenLink/releases) 分发。

一次 `./build.sh` 就会在 `dist/` 产出两个同名不同格式的安装包（版本号自动取自 `Info.plist` 的 `CFBundleShortVersionString`）：

| 产物 | 生成方式 | 用途 |
|---|---|---|
| `ScreenLink-<版本>.dmg` | `hdiutil create -format UDZO`，内含 App + `/Applications` 快捷链接 | 主安装包，双击挂载拖拽即装 |
| `ScreenLink-<版本>.zip` | `ditto -c -k --keepParent`（保留 bundle 结构，不产生 `__MACOSX`） | 备用，适合 `curl`/命令行部署 |

发布步骤：打好 `vX.Y` 标签推到远端 → 在 Releases 建同名 release → 上传 `dist/` 下的 `.dmg` 与 `.zip`（资产名带版本号，README 安装说明按 `ScreenLink-<版本>.dmg` 写）。App 为 ad-hoc 签名、未做公证，首次打开需右键 → 打开。

## 配置与数据

| 路径 | 内容 |
|---|---|
| `~/sscreenlink/` | 状态文件（`saver-wanted` / `force-hold` / `keep-awake` / `role` / `reload-settings`） |
| `~/sscreenlink-app.log` → `/tmp/screenlink-app.log` | 运行日志，含 SSH 失败的 stderr 全文 |
| `~/Library/LaunchAgents/com.think.screenlink.app.plist` | 勾选「登录时启动」后生成 |
| `defaults read com.think.screenlink.app` | 所有开关的当前值；生效时间段存为 `<开关名>Win`（如 `holdRemoteWin = "22:00-07:00"`），是否启用该时段存为 `<开关名>WinOn`（取消勾选不清已配时段），缺省全天 |

## 常见问题

**远端没反应 / 日志里 `rc=255`**
先手动跑一次 `ssh -o BatchMode=yes <peer> 'echo OK'`。失败多为：未配置免密、从动端「远程登录」未开、或 App 的「本地网络」权限未授权。

**远端进了屏保但退不出来**
从动端开启了「需要密码解锁」的强制锁屏，程序化唤醒会被拦。用 `sysadminctl -screenLock status` 确认。

**菜单栏图标不见了**
联动仍在后台运行。再点一次 ScreenLink（访达 / 启动台 / Spotlight）图标就回来；也可以在终端 `open -a ScreenLink`。

**两台机器都设成了从动**
没有任何一台会下发，联动不生效。至少一台要是主控。

## 贡献

Issues 与 PR 欢迎。改动源码后请先本地 `./build.sh` 验证能编译、产出 DMG/ZIP；构建产物不入库（见[打包与发布](#打包与发布)）。提交按功能逻辑拆分，信息说明改动动机。

## 许可证

[Apache License 2.0](LICENSE)
