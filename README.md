# DeepSeek Harness — macOS 原生壳

一个零外部依赖的原生 macOS App（Swift + AppKit + WKWebView）。双击打开后，
它自动拉起（或复用）`dsh web` 服务，用标准 macOS 原生窗口展示现有 Web GUI；
**页面 UI 零改动**，壳本身只提供原生窗口、菜单栏和进程保活。

本目录是独立项目：源码自维护（自带 git 仓库），不依赖 deepseek-harness
仓库的任何源码。App 运行时使用 npm 安装的 `dsh` CLI
（`npm i -g @deepseek-ai/dsh`，或自动回退到 `~/.npm/_npx` 缓存）。

## 行为约定（按 macOS 惯例）

- **双击 App**：自动探测 `127.0.0.1:3080`。
  - 已有 `dsh web` 在跑 → 直接复用（窗口里就是那个页面），退出时不碰它；
  - 没有 → App 作为子进程拉起 `dsh web`（经登录 shell，继承 `~/.zshrc` 等环境），
    解析 `dsh web: http://127.0.0.1:<port>` 就绪行后加载页面；
  - 端口被其他程序占用 → 换一个系统分配的空闲端口。
- **Cmd+W / 红灯关窗**：只关窗口，App 留在 Dock、服务继续运行；
  点 Dock 图标重新弹出窗口（页面状态保留）。
- **Cmd+Q / 退出**：App 退出，并优雅停止**它自己拉起**的服务（SIGTERM，7 秒兜底 SIGKILL）；
  复用的既有服务永不误杀。
- **保活**：服务意外崩溃后 2 秒自动重启（60 秒内最多 3 次，超过弹窗报错）。
- **单实例**：重复双击聚焦已有窗口，不会起第二个服务。
- **未安装 dsh**：弹原生对话框，可一键 `npm i -g @deepseek-ai/dsh`。
- 外部链接、`target="_blank"` 一律交给默认浏览器，不会顶掉 App 内页面。
- 菜单栏提供：关于 / 退出、编辑（撤销/剪贴板）、重新加载 (⌘R)、在浏览器中打开 (⇧⌘O)、窗口。
- 标题栏为透明样式：无标题栏与内容之间的分割线，保留原生标题文字与红绿灯按钮；
  条带颜色运行时取页面侧栏色（`--dsw-specific-sidebar-fill` 令牌），随页面深浅主题自动跟随。

日志：`~/Library/Logs/DeepSeekHarness/deepseek-harness.log`。

## 构建

要求：Xcode 命令行工具（`swift`、`iconutil`），无需任何第三方依赖。

```sh
./build.sh
# 产物：dist/DeepSeek Harness.app
```

## 运行

```sh
open "dist/DeepSeek Harness.app"
# 或安装到应用程序目录（推荐，启动器只认这里）：
cp -R "dist/DeepSeek Harness.app" ~/Applications/
```

也可直接跑二进制并传调试参数（`open -a "DeepSeek Harness" --args ...`）：

| 参数 | 作用 |
| --- | --- |
| `--port <n>` | 强制指定服务端口（默认探测 3080） |
| `--spawn` | 总是新起一个 `dsh web`，不复用已有实例 |
| `--cwd <dir>` | 子进程工作目录（默认 `$HOME`） |
| `--dsh <path>` | 指定 `dsh` 可执行文件路径 |
| `--direct` | 不走登录 shell，直接执行 dsh |
| `--log <path>` | 日志文件路径 |

## 设计决策（为什么这样做）

- **Swift + WKWebView 而非 Tauri**：同一个 WKWebView 壳，Tauri 还需 Rust 工具链和更重的构建链，
  而 Swift/AppKit 每台 Mac 随 Xcode 附带。
- **不用 Electron**：非原生、体积大，与原生 macOS 设计相悖。
- **不用 LaunchAgent + Safari PWA**：零原生代码但无真正的 App 包、图标、单实例窗口管理与进程生命周期控制。
- **attach 优先而非总是新起服务**：避免与用户已有实例产生重复服务与页面；
  以页面标题标记探测识别 dsh web，仅在无人应答时才拉起。
- **WKWebView 只在主线程操作**：URLSession 探测回调先跳回主队列再通知 delegate，
  页面加载入口再做一次主线程检查（第一版曾因后台线程加载页面触发 WebKit SIGTRAP 崩溃）。
- **标题栏条带取页面侧栏色**：页面两侧颜色几乎相同（浅色 249,250,251 vs 255,255,255），
  所以用侧栏色给全宽条带上色，左右视觉上都连续；颜色与深浅主题由注入的页面脚本采样
  （CSS 令牌 + `data-ds-dark-theme`），令牌缺失时回退系统窗口色。
- **默认工作目录为用户主目录**：与 `dsh web` 终端手启一致；可用 `--cwd` 覆盖。

## 说明

- App 未开沙箱（无 entitlements），否则无法管理子进程；本地产物 ad-hoc 签名，
  可直接运行，不触发 Gatekeeper 隔离。
- 开机自启可手动在「系统设置 → 通用 → 登录项」里添加本 App（可选）。
- 若构建产物被 `open` 启动过，会被 macOS 启动器（Launchpad/聚焦）登记；
  日常请只从 `~/Applications` 打开，避免启动器出现两个同名图标。

## 结构

```
Package.swift                     SPM 包（macOS 13+，无外部依赖）
Sources/DSHMac/
  main.swift                      入口
  LaunchOptions.swift             命令行参数
  AppLog.swift                    文件日志
  ServerController.swift          dsh 探测/拉起/就绪/保活/停止
  WebViewController.swift         WKWebView + 加载状态层
  AppDelegate.swift               窗口、菜单、单实例、安装流程
Info.plist
scripts/make-icon.swift           图标生成（SF Symbol + 渐变）
build.sh                          构建并组装 .app（ad-hoc 签名）
```
