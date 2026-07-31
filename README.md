<h1 align="center">Vitals v1.0.0</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0+-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/SwiftPM-FA7343?style=flat-square&logo=swift&logoColor=white" alt="SwiftPM">
  <img src="https://img.shields.io/badge/macOS-14+-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/IOKit-FF6F00?style=flat-square&logo=apple&logoColor=white" alt="IOKit">
  <img src="https://img.shields.io/badge/Keychain-0078D8?style=flat-square&logo=apple&logoColor=white" alt="Keychain">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  macOS 桌面浮窗系统监控 + MiniMax 用量面板 — CPU / 内存 / 磁盘 / 网络 / 电源 / 进程实时采集。<br>
  <b>支持拖拽、缩放、锁位置、模块开关，菜单栏常驻。</b>
</p>

---

## 功能特点

- **桌面浮窗**：always-on-top 浮窗，可拖拽 + 缩放，锁位置
- **菜单栏常驻**：MenuBarExtra 实时显示 CPU/内存/网络/磁盘指标
- **六大模块**（可独立开关）：
  - **CPU**：总占用 + 温度 + Top 3 核心 + 负载 + 趋势 sparkline
  - **内存**：已用/空闲/缓存/可用 + 分级配色
  - **磁盘**：占用 + I/O 速度（IOKit IOBlockStorageDriver）
  - **网络**：下载/上传速率 + 接口名 + IP
  - **电源**：电量 + 健康度 + 充放电状态 + 电池温度
  - **进程**：Top 3 进程按 CPU
- **MiniMax 用量集成**：
  - 5h 限额 + 周限额实时查询
  - 自带"Xh Ym 后重置"倒计时
  - macOS Keychain 安全存 cookie
  - 1/5/15/30/60 分钟可配刷新频率
  - **菜单栏指标**：可选"5h" / "week" 列显示（参照 CPU/MEM 模式）
- **SMC CPU 温度**：Apple Silicon die 温度中位数（防单点传感器异常）
- **极简 SwiftUI 主题**：Catppuccin 配色，3 档字体大小 + 系统/等宽 2 档字体
- **后台采样能耗优化**：Timer tolerance 让 macOS 合并唤醒
- **启动时间锁保护**：killStaleWidgetProcess 启动时清旧进程

### 本分支新增

- 集成 **MiniMax 用量模块**：5h 限额 + 周限额 + 倒计时
- 菜单栏指标新增 **MiniMax 5h** + **MiniMax 周** 选项（默认关闭，可独立勾选）
- 集成 **macOS Keychain** 存储 MiniMax 认证（3 个 cookie）
- **设置面板**支持自定义 MiniMax 刷新间隔（1/5/15/30/60 分钟）
- **删除 Ko-fi 支持按钮** + **删除 GitHub 链接 / 反馈问题 / 自动检查更新**
- **删除"用量历史…"窗口**（24h 历史采样功能）
- **删 Swift Sparkle 依赖**（精简包体 81%）
- **桌面浮窗标题栏删除**（Vitals 名 + S/M/L 按钮 + 锁定 + 隐藏）
- **所有用户可见英文 → 中文硬编码翻译**（菜单/标签/帮助/单位）
- **电源状态修复**：用 AppleSmartBattery 注册表替换 IOKit IOPS API（解决 macOS 26 缓存不一致问题）
- **App Group ID 简化**：使用 hardcoded 容器路径替代 App Groups（更简单的安装流程）

---

## 快速开始

### 1、直接下载

从 [Releases](https://github.com/smryyyyy/Vitals/releases) 下载 `Vitals.dmg`，双击挂载后拖入 `/Applications` 即可。

启动后桌面会显示浮窗（首次需在**系统设置 → 隐私与安全性 → 辅助功能**允许）。

### 2、自行构建

需要 Xcode 16+ / Swift 6.0+，macOS 14+：

```bash
git clone https://github.com/smryyyyy/Vitals.git
cd Vitals
make app
# 产物: dist/Vitals.app
```

打包 DMG：

```bash
mkdir -p /tmp/vitals_dmg
cp -R dist/Vitals.app /tmp/vitals_dmg/Vitals.app
ln -s /Applications /tmp/vitals_dmg/Applications
hdiutil create -srcfolder /tmp/vitals_dmg -volname Vitals -o ~/Desktop/Vitals.dmg
```

> **注意**：本项目用 `Swift Package Manager` 而非 Xcode 工程。`Package.swift` 是入口，`make app` 把二进制 + Info.plist + AppIcon.icns 拼成 .app bundle。

### 3、MiniMax 用量配置

1. 启动 Vitals 后，菜单栏图标 → **MiniMax 设置…**
2. 在 Chrome 登录 [platform.minimaxi.com](https://platform.minimaxi.com)
3. F12 → Network → 找 `www.minimaxi.com` 开头的请求 → 右键 → **Copy as cURL (bash)**
4. 从 cURL 里的 `-H 'Cookie: ...'` 提取 3 个值：
   - `_token` (JWT 格式 `eyJ...`)
   - `HERTZ-SESSION`
   - `minimax_group_id_v2`
5. 填到 Vitals 设置面板 → **测试连接** → **保存**
6. 桌面浮窗会出现 **MiniMax section**（5h + 周 + 倒计时）

**Cookie 过期处理**：HERTZ-SESSION 约 30 天过期，过期后桌面浮窗显示"认证失败"。重新登录抓 cookie 再填即可。

---

## 使用说明

| 操作 | 说明 |
|------|------|
| 拖拽浮窗 | 鼠标按住浮窗任意位置移动（解锁时） |
| 缩放浮窗 | 拖拽右侧边缘 |
| 菜单栏图标 | 右键 → 设置 / 退出 / 模块开关 |
| 锁定位置 | 菜单 → 锁定位置（关闭拖拽） |
| 显示/隐藏 | 菜单 → 显示在桌面（关闭后只显示菜单栏） |
| 模块开关 | 菜单 → 模块 → 勾选要显示的 section |

### 菜单栏 MiniMax 指标

- 菜单 → 设置 → 菜单栏指标 → 勾选 **MiniMax 5h** / **MiniMax 周**
- 菜单栏图标会按 `5h / 13%` 或 `week / 45%` 形式显示当前用量
- 默认关闭（避免菜单栏过长）
- 刷新频率跟随设置面板（默认 5 分钟）

### MiniMax 刷新策略

- **默认 5 分钟**（推荐，平衡实时性 vs 风险控）
- 可在设置面板改成 1/5/15/30/60 分钟
- 1 分钟风险高（可能被后端风控），建议 5+
- Cookie 存 **macOS Keychain**（系统级加密，App 卸载也不丢——除非手动 `security delete-generic-password`）

### 性能开销

- CPU 采集：~1 ms / 次（host_processor_info）
- 内存采集：~0.5 ms / 次（host_statistics64）
- 磁盘 I/O：~2 ms / 次（IOKit 遍历 IOBlockStorageDriver）
- 进程采集：~10 ms / 次（proc_listallpids + proc_pid_rusage）
- 温度采集：~5 ms / 首次扫描，后续 ~0.1 ms（缓存 SMC keys）
- 菜单栏刷新：默认 2 秒（可在设置调 1/2/5 秒）

**总开销 < 1% CPU**（除首次启动扫描 SMC）。

---

## 项目结构

```bash
Vitals/
├── Sources/
│   ├── MoleWidget/
│   │   └── MoleWidgetApp.swift         # 主 App: AppDelegate + MenuBarExtra + DesktopWindow
│   └── MoleWidgetCore/                 # 核心库 (可被 widget extension 复用)
│       ├── CoreInfo.swift / History.swift / WidgetSettings.swift
│       ├── CPU/ (Collector + Usage + Types)
│       ├── Memory/ (Collector + Usage + Types)
│       ├── Disk/ (Collector + IO + Types)
│       ├── Network/ (Collector + IO + Types)
│       ├── Power/ (Collector + SMC + BatteryMath + Types)
│       ├── Processes/ (Collector + Math + Types)
│       ├── System/ (SystemInfo + HealthScore)
│       ├── Formatting/ (Fmt + MenuBarText)
│       ├── Views/ (10 个 UI 组件)
│       ├── Store/MetricsStore.swift   # @MainActor @Observable 中央数据 store
│       └── MiniMax/                    # MiniMax 集成 (5 个文件)
│           ├── MinimaxTypes.swift
│           ├── MinimaxClient.swift    # URLSession + Cookie 认证
│           ├── MinimaxMapper.swift    # JSON → Snapshot
│           ├── MinimaxKeychain.swift  # macOS Keychain 凭据存储
│           └── MinimaxManager.swift   # @MainActor @Observable 5min 定时器
├── Resources/
│   ├── AppIcon.icns
│   └── Info.plist
├── Scripts/
│   └── make-icon.swift                # 图标生成
├── Tests/
│   └── MoleWidgetCoreTests/ (16 文件)
├── Package.swift                       # SwiftPM 入口
├── Makefile                            # 打包 .app
└── README.md
```

---

## 技术栈

| 组件 | 用途 |
|------|------|
| Swift 6.0+ / SwiftUI | 主 UI + 桌面浮窗 |
| AppKit (NSWindow / NSHostingView) | 浮窗层级 / 透明度 / 鼠标事件 |
| IOKit (mach / IOBlockStorageDriver) | CPU/内存/磁盘原始采集 |
| SystemConfiguration (SCDynamicStore) | 网络接口信息 |
| libproc (proc_listallpids) | 进程 CPU/内存 |
| AppleSMC kernel API | CPU die 温度 |
| @Observable (Swift 5.9+) | 响应式数据流 |
| URLSession async/await | MiniMax API |
| Security framework (SecItem) | Keychain |
| Sparkle (已移除) | (历史) 自更新 |

---

## 常见问题

### MiniMax 显示"认证失败"

Cookie 过期了（HERTZ-SESSION 约 30 天，_token 约 39 天）。重新登录 platform.minimaxi.com 抓新 cookie，填到 Vitals → MiniMax 设置。

### 桌面浮窗不显示

检查菜单栏图标 → "显示在桌面" 勾上。或者看 **系统设置 → 桌面与 Dock** 是否被"使用舞台管理"隐藏。

### CPU 温度显示 "—"

Apple Silicon 才有 SMC 温度传感器。Intel Mac / 沙盒化进程拿不到，会显示 nil → UI 自动降级到只显示占用。

### 应用签名警告

`Vitals.dmg` 用 ad-hoc 签名（`codesign --sign -`），首次打开可能 Gatekeeper 拦截。**右键 → 打开** 即可，或 `xattr -dr com.apple.quarantine /Applications/Vitals.app`。

### 想编译报错 "cannot find 'Sparkle'"

本分支已删除 Sparkle 依赖。如果 fork 自早期版本，先 `make clean` 再 build。

### 菜单栏 MiniMax 不显示

先在 菜单 → 设置 → 菜单栏指标 勾选 **MiniMax 5h** 或 **MiniMax 周**。
未勾选时默认不显示，避免菜单栏过长。

---

## 许可证

MIT License

---

## 致谢

本项目基于 [mole-widget](https://github.com/TadelUnso/mole-widget) 修改而来，感谢原作者的出色设计。

主要改动：
- 中文化（菜单 / 标签 / 帮助 / 单位）
- 桌面浮窗标题栏去除（更简洁）
- 删除 Ko-fi / GitHub 链接 / Sparkle 自动更新
- 删除"用量历史"窗口
- 集成 MiniMax 用量 API（5h + 周 + 倒计时）
- macOS Keychain 存储凭据

---

*本软件由 AI 辅助编写。*
