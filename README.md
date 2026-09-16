<h1 align="center">Vitals v1.2.0</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0+-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/SwiftPM-FA7343?style=flat-square&logo=swift&logoColor=white" alt="SwiftPM">
  <img src="https://img.shields.io/badge/macOS-14+-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/IOKit-FF6F00?style=flat-square&logo=apple&logoColor=white" alt="IOKit">
  <img src="https://img.shields.io/badge/Keychain-0078D8?style=flat-square&logo=apple&logoColor=white" alt="Keychain">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="MIT License">
</p>

<p align="center">
  macOS 桌面浮窗系统监控 + MiniMax 用量面板 + 实时工资看板 — CPU / 内存 / 磁盘 / 网络 / 电源 / 进程 / 工资 七大模块实时数据。<br>
  <b>支持拖拽、缩放、锁位置、模块开关，菜单栏常驻。</b>
</p>

---

## 功能特点

### 系统监控

- **桌面浮窗**:always-on-top 浮窗,可拖拽 + 缩放,锁位置
- **菜单栏常驻**:MenuBarExtra 实时显示 CPU/内存/网络/磁盘指标
- **七大模块**(可独立开关):
  - **CPU**:总占用 + 温度 + Top 3 核心 + 负载 + 趋势 sparkline
  - **内存**:已用/空闲/缓存/可用 + 分级配色
  - **磁盘**:占用 + I/O 速度(IOKit IOBlockStorageDriver)
  - **网络**:下载/上传速率 + 接口名 + IP
  - **电源**:电量 + 健康度 + 充放电状态 + 电池温度
  - **进程**:Top 3 进程按 CPU
  - **工资**:实时显示今日已赚 / 本月累计 / 本年累计 / 在职累计,支持税后月薪、上下班时间、午休时段、工作模式设置,按中国法定节假日 + 调休自动算月工作日
- **SMC CPU 温度**:Apple Silicon die 温度中位数(防单点传感器异常)
- **后台采样能耗优化**:Timer tolerance 让 macOS 合并唤醒
- **启动时间锁保护**:killStaleWidgetProcess 启动时清旧进程

### MiniMax 用量集成

- 5h 限额 + 周限额实时查询
- 自带"Xh Ym 后重置"倒计时
- macOS Keychain 安全存 cookie(3 个:\_token / HERTZ-SESSION / minimax\_group\_id\_v2)
- 1/5/15/30/60 分钟可配刷新频率
- **菜单栏指标**:可选 "5h" / "week" / "工资" 列显示(参照 CPU/MEM 模式)

### 截图模块

- **快速截图 / 高级窗口截图**:Carbon 全局快捷键(默认 ⇧⌘2 / ⇧⌃⌥A)
  - 框选区域 → 复制到 NSPasteboard(不存文件、不存历史)
  - 在 MiniMax 设置 → 截图设置 可改键
  - Carbon 签名 "Vtls"(与 Mio "Mio1" 区分)
  - 权限检查:Screen Recording + Accessibility,授权后 Carbon hotkey 自动重注册
- **编辑器**(8 个标注工具 + 颜色选择器 + 撤销/重做)
  - 箭头 / 矩形 / 圆 / 线条 / 文字 / 马赛克 / 自由笔
  - 马赛克在 Apple Silicon GPU 上生成(IOBlockStorageDriver 实时编码)
  - 编辑完成点"完成"→ 复制 + 关编辑器 + Dynamic Island 反馈
- **OCR 识别**(macOS Vision 本地 + 免费 + 离线)
  - VNRecognizeTextRequest 带 bounding box,2 秒超时 + ResumeOnce
  - 跨实例画布 SHA256 hash 缓存(5 分钟 TTL,同画布不重跑 Vision)
  - 失败可点"重试"按钮(invalidate cache 后重跑)
- **AI 翻译**(MiniMax chatcompletion\_v2 + 段落覆盖兜底)
  - 用户自配 MiniMax API Key,存 macOS Keychain(服务 ID `com.skyline.vitals.ocr.aikey`)
  - 6 状态机:idle / ocrLoading / completed / translating / translated / failed
  - 4 路径响应解析(JSON 匹配 / JSON 不匹配 / 非 JSON split 匹配 / 非 JSON split 不匹配)
  - 段落覆盖兜底:模型合并多行时整段覆盖在 firstOriginalLine,放弃逐行对应
  - 翻译后画布缓存(`translatedCanvasData`),让用户点"提取文字"按译文图重新 OCR
- **截图设置窗口**(权限 + API Key + 目标语言)
  - 快捷键录制(顶部"录制"按钮 + Backspace 清除,X/重置按钮已删)
  - 权限状态(Screen Recording + Accessibility)+ 跳转系统设置
  - API Key 输入(SecureField + 250ms debounce 写 Keychain,避免频繁 securityd IPC)
  - 目标语言输入框(默认"简体中文",250ms debounce 写 UserDefaults)
  - 关编辑器时同步 flush pending 写盘,避免最后一次语言设置丢失

### 主题与体验

- **极简 SwiftUI 主题**:Catppuccin 配色,3 档字体大小 + 系统/等宽 2 档字体
- **跨语言**:所有用户可见英文 → 中文硬编码翻译(菜单/标签/帮助/单位)
- **可定制**:7 大模块独立开关,菜单栏指标可选列,快捷键自定义

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

### 截图操作

| 操作 | 触发 | 说明 |
|------|------|------|
| 触发截图 | ⇧⌘2 / ⇧⌃⌥A | 全局快捷键,可在截图设置窗口改键 |
| 编辑标注 | 编辑器打开后 | 8 个工具按钮 + 颜色选择器 |
| OCR 识别 | 编辑器 → 识别 | macOS Vision 本地识别,1-3 秒 |
| 翻译 | 编辑器 → 翻译 | MiniMax API 翻译,3-5 秒 |
| 一键复制 | 翻译完成后 | 复制译文到剪贴板 |

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
│       ├── Views/ (12 个 UI 组件,含 Salary section/settings)
│       ├── Store/MetricsStore.swift   # @MainActor @Observable 中央数据 store
│       └── MiniMax/                    # MiniMax 集成 (5 个文件)
│           ├── MinimaxTypes.swift
│           ├── MinimaxClient.swift    # URLSession + Cookie 认证
│           ├── MinimaxMapper.swift    # JSON → Snapshot
│           ├── MinimaxKeychain.swift  # macOS Keychain 凭据存储
│           └── MinimaxManager.swift   # @MainActor @Observable 5min 定时器
│       └── Salary/                    # 实时工资模块 (4 个文件)
│           ├── SalaryTypes.swift      # SalarySettings / SalarySnapshot / SalaryState
│           ├── SalaryEngine.swift     # 纯计算引擎
│           ├── SalaryManager.swift    # @MainActor @Observable 1秒定时器
│           └── ChineseWorkdayCalendar.swift  # 国务院 2024-2026 放假调休表
│       └── Screenshot/                # 截图模块 (本轮新增,46 个文件)
│           ├── ScreenshotServices.swift       # 顶层协调
│           ├── ScreenshotTypes.swift
│           ├── Permission/ (PermissionManager + SystemSettings)
│           ├── Hotkey/ (GlobalShortcutService "Vtls" 签名 + ShortcutRecorderControl 等 6 文件)
│           ├── OutputDelivery/ (ClipboardOutputService 等 2 文件)
│           ├── Capture/ (CapturePipeline + CaptureSession + 等 6 文件)
│           ├── Selection/ (WindowHitTester + SelectionPresenter 等 5 文件)
│           ├── Editor/ (12 文件,含 AIPanel + 8 工具工具栏)
│           ├── OCR/ (VisionOCRClient + MiniMaxTranslationClient + OCRService 等 6 文件)
│           ├── ImageProcessing/ (3 文件)
│           └── Settings/ (CaptureSettings + ScreenshotSettingsView)
├── Resources/
│   ├── AppIcon.icns
│   └── Info.plist
├── Scripts/
│   └── make-icon.swift                # 图标生成
├── Tests/
│   └── MoleWidgetCoreTests/ (17 文件)
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
| Carbon (RegisterEventHotKey) | 全局快捷键,签名 "Vtls" |
| Vision (VNRecognizeTextRequest) | 本地 OCR 识别 |
| CryptoKit | OCR 画布 hash 缓存(SHA256) |
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

### 工资 section 显示"节假日表已过期"

内嵌的中国法定节假日表覆盖 2024-2026 三年（来自国务院办公厅通知原文）。2027 年起系统会走默认"周一~五"规则，并在浮窗顶部 + 设置页加红字提示。**手动更新**：每年 12 月等国务院发新通知后，把数据追加到 `Sources/MoleWidgetCore/Salary/ChineseWorkdayCalendar.swift` 的 table 字典，然后 `make build` 重新打包。

### 截图快捷键不生效

检查截图设置窗口的"权限"section:屏幕录制 + 辅助功能都必须授权。

- macOS 14+:辅助功能授权后 Vitals 自动重新注册 hotkey,无需重启
- 不需要重启,授权后 1 秒内自动生效

### OCR 翻译失败

- 检查截图设置窗口的 MiniMax API Key 是否填写
- 网络问题看 OCRService 错误提示
- MiniMax 模型偶发合并多行,系统自动降级到"段落覆盖"模式(整段译文覆盖在第一行)

---

## 许可证

MIT License

---

## 致谢

本项目基于 [mole-widget](https://github.com/TadelUnso/mole-widget) 修改而来，感谢原作者的出色设计。

---

*本软件由 AI 辅助编写。*
