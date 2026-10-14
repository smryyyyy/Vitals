# 已知缺陷清单

本文是一次**纯静态代码审查**的产出，记录 Vitals v1.2.0 中已定位但尚未修复的缺陷。

审查日期：2026-10-14。审查全程只读源码，**未运行应用、未执行构建、未跑测试**。因此本文所有结论均来自源码阅读，标注「待验证」的条目需要在实机上确认后才能定论。行号对应审查当时的提交，后续改动后请以符号名为准。

严重程度分三档：

- **P0** — 会持续产生错误数值或出现明显功能故障
- **P1** — 可能卡死、崩溃，或体验明显受损
- **P2** — 正确性偏差与文档不一致

---

## P0 — 会持续产生错误数值或明显故障

### 1. 网络速率计数器 32 位回绕

- **位置**：`Sources/MoleWidgetCore/Network/NetworkCollector.swift:31-32`
- **现象**：把每个网卡的 `if_data.ifi_ibytes` / `ifi_obytes` 累加成总计数器。两个字段在 SDK 中是 `u_int32_t`，累计到 4.29 GB 后回绕；累加器变小被下游判成「计数器重置」，该帧速率记为 0。表现为网络速率周期性掉到 0。
- **触发条件**：单网卡累计流量越过 2^32 字节。100 MB/s 传输下约每 43 秒触发一次。
- **修法方向**：改用 `if_data64`（需走 `if_msghdr2` 接口），或在回绕时按 2^32 做模运算补偿。

### 2. MiniMax 刷新频率设置改动不生效

- **位置**：`Sources/MoleWidgetCore/MiniMax/MinimaxManager.swift:25`（`public static let interval: TimeInterval`）
- **现象**：`interval` 是 `static let`，进程内只求值一次。设置页修改频率后调用 `restart()` → `start()`，读到的仍是缓存值，必须重启应用才生效。
- **触发条件**：用户在设置页修改 1/5/15/30/60 分钟任一档位后返回。
- **修法方向**：改为读取 UserDefaults 的计算属性，或在设置变更时同步更新静态存储。该文件 `:23-24` 的注释描述与当前实现不一致，需一并修订。

### 3. 节假日表过期提示未接入 UI

- **位置**：`Sources/MoleWidgetCore/Salary/SalaryEngine.swift:11`（计算）→ `Sources/MoleWidgetCore/Salary/SalaryTypes.swift:81,118`（存入 `SalarySnapshot`）
- **现象**：`tableExpired` 全仓库仅在 `Salary/` 目录内被写入和传递，`Sources/MoleWidgetCore/Views/Sections/SalarySectionView.swift` 与 `SalarySettingsView.swift` 中均无读取点。2027 年起会静默按「周一~五」规则计算工作日，用户无感知；跨年时当月工作日数变化还会导致日薪跳变。
- **触发条件**：内置节假日表覆盖范围结束后的年份，即 2027 年起自动出现。
- **修法方向**：在浮窗顶部与设置页读取 `snapshot.tableExpired` 并展示红字提示。`README.md:312-314` 已描述该提示，目前尚未实现。

### 4. 截图流程不预检查权限

- **位置**：`Sources/MoleWidgetCore/Screenshot/Permission/PermissionManager.swift:83,88`
- **现象**：`currentScreenCaptureDecision()` 与 `currentAccessibilityDecision()` 两个实时查询 API 除定义处外全项目零调用。未授权时按快捷键，ScreenCaptureKit 抛 `permissionDenied` 后统一进入 `.failed` 分支（`Screenshot/Capture/CapturePipeline.swift`），界面不区分权限原因，也没有跳系统设置的引导。`PermissionRecovery` 仅在设置窗口内可用。
- **触发条件**：用户未授权屏幕录制或辅助功能，直接按截图快捷键。
- **修法方向**：在快捷键入口处先查权限，未授权时直接进入带跳转引导的失败态。

### 5. 工资模块跨午夜班次计算错误

- **位置**：`Sources/MoleWidgetCore/Salary/SalaryEngine.swift:363-367`
- **现象**：`todayAt` 使用 `date(bySettingHour:)` 落在当天。若下班时间设为凌晨 02:00（即 120 分钟），`clockOut - clockIn` 为负，`totalWorkMinutes = 0`，全天进度恒为 0；且 `now < clockIn` 持续成立，界面一直显示「距上班还有」。
- **触发条件**：上下班时间跨越午夜（下班时刻早于上班时刻）。
- **修法方向**：`todayAt` 需按 `clockOut < clockIn` 判定并把下班时刻归到次日。日薪算法本身正确：下班时刻的 earned 恰好等于日薪，午休在分母、分子、进度三处扣除一致。

---

## P1 — 可能卡死、崩溃、或体验明显受损

### 6. 自定义光标回滚存在跳过路径

- **位置**：`Sources/MoleWidgetCore/Cursor/CGSCursorBridge.swift:186,233-242`
- **现象**：三处静默失败。`unregisterAll` 返回非 0 时只打日志、无重试；`reload()` 在 `getCursorScale` 或缩放扰动失败时提前 return，跳过收尾的 `setSystemDefinedCursor(conn, 0)`，而该调用正是清除服务端旧缓存的关键。应用内无二次兜底路径。
- **触发条件**：WindowServer 状态异常、macOS 更新导致私有 API 行为变化，或缩放写入失败。
- **修法方向**：`reload()` 用 `defer` 保证回滚调用一定执行；`unregisterAll` 失败时加入有限次重试。

### 7. 光标注册在主线程持锁调用 WindowServer

- **位置**：`Sources/MoleWidgetCore/Cursor/CGSCursorBridge.swift:151-159,224-247`
- **现象**：`register` 和 `reload` 在持有 `NSLock` 时进入 CGS 调用，而所有调用均来自主线程，且在唤醒通知回调中同步执行（`Cursor/CursorThemeService.swift:394-408` 只监听 `didWake`）。睡眠唤醒早期若 WindowServer 未就绪，此处可无限期阻塞，冻结整个 UI，无超时或异步逃生口。
- **触发条件**：睡眠唤醒瞬间启用光标主题，或系统刚启动时勾选开关。
- **修法方向**：CGS 调用移出锁范围与主线程，加超时与降级路径。
- **附带问题**：`dlsym` 返回 NULL 已做检查（`CGSCursorBridge.swift:111-123`，9 个符号缺任一即整体降级为空操作），但 `resolve` 只做 `unsafeBitCast`，不校验符号所属镜像（`:265-267`）。若同名符号来自签名不同的库，会得到错误 ABI 的函数指针。建议加镜像来源校验，或在开发期加断言。

### 8. 菜单跟踪与窗口拖拽期间采样停摆

- **位置**：`Sources/MoleWidgetCore/Store/MetricsStore.swift:59-64,75`
- **现象**：四个采样定时器通过 `Timer.scheduledTimer` 创建，只注册在默认 RunLoop 模式。菜单跟踪和窗口拖拽期间事件跟踪模式接管 RunLoop，四个定时器全部停摆。
- **触发条件**：长按菜单栏图标，或持续拖拽浮窗。菜单栏常驻工具属于高频场景。
- **修法方向**：定时器同时注册到 `.common` 模式。

### 9. SMC 温度传感器列表失败后永久缓存

- **位置**：`Sources/MoleWidgetCore/Power/SMCTemperature.swift:35-36`
- **现象**：`let keys = cpuKeys ?? discoverCPUKeys(); cpuKeys = keys` 无条件写回。若首次扫描失败（沙盒化进程、无 SMC 权限等），空数组被缓存，此后 `cpuTemperature()` 永远返回 nil，只能重启进程恢复。
- **触发条件**：进程启动后首次传感器扫描失败。
- **修法方向**：仅在结果非空时写回缓存。
- **附带问题**：`:63` 处 `median > 110` 直接整帧返回 nil，该阈值比单传感器的 130 严格得多，可能过早丢弃有效读数。待定：阈值取值依据。

### 10. OCR 翻译存在陈旧响应写入竞态

- **位置**：`Sources/MoleWidgetCore/Screenshot/OCR/OCRService.swift:269`
- **现象**：`startTranslation` 在 `await` 之后直接写 status 和 overlay，无 in-flight 身份校验。客户端超时窗口为 15 秒（`Screenshot/OCR/MiniMaxTranslationClient.swift:69`），窗口内用户点「重试」，旧响应后到会覆盖新状态。`VisionOCRClient.ResumeOnce:112` 只防 double-resume，无法防此问题。
- **触发条件**：翻译请求未超时的 15 秒内点击重试，或快速切换画布。
- **修法方向**：为每次请求分配 token，写回前校验 token 仍为最新。

### 11. 编辑器窗口重试路径可能触发 preconditionFailure

- **位置**：`Sources/MoleWidgetCore/Screenshot/Editor/EditorWindowController.swift:294`
- **现象**：实现假设「部分重试不可能全部失败」，但剪贴板被其他应用占用时 `retryPendingSinks` 会返回 `failed`。Debug 构建直接崩溃，Release 构建静默停留在 retrying 状态。
- **触发条件**：剪贴板写入被其他应用独占，且编辑完成后的重试路径被触发。
- **修法方向**：去掉该前置条件断言，或让失败态正常收敛到 failed。

### 12. Keychain 读取把多种错误折叠为「未配置」

- **位置**：`Sources/MoleWidgetCore/MiniMax/MinimaxKeychain.swift:45-47`
- **现象**：`load()` 将 `errSecItemNotFound`、`errSecInteractionNotAllowed`（钥匙串锁定，因使用 `kSecAttrAccessibleWhenUnlocked`）、权限拒绝全部折叠为 nil，上层统一显示「未配置」（`MiniMax/MinimaxManager.swift:75-78`）。
- **触发条件**：屏幕锁定期间或首次解锁前查看 MiniMax 面板。
- **修法方向**：区分「未配置」与「暂时不可读」，对 `errSecInteractionNotAllowed` 单独提示。

---

## P2 — 正确性偏差与文档不一致

### 13. 内存统计口径与活动监视器不一致

- **位置**：`Sources/MoleWidgetCore/Memory/MemoryUsage.swift:10,12`
- **现象**：`used = active + wired + compressed`，未计入 `inactive` 与 `speculative`（`Memory/MemoryTypes.swift:11-12` 注释中已承认）。活动监视器的 App Memory 含 inactive 中的匿名页，因此此处 used 系统性偏低；`free = total - used` 又把所有 inactive 与文件缓存计入空闲。两者互补自洽（测试 `Tests/MoleWidgetCoreTests/MemoryTests.swift:37` 明确断言 `used + free == total`），但与活动监视器数字不同。
- **附带问题**：`cached = purgeable + external` 中 purgeable 是 external 的子集，存在重复计数，`available` 会略高于内核真实可用量。
- **修法方向**：待定。是改为贴近活动监视器口径，还是在 UI 上标注口径差异，需产品层面决定。实际差值见「待验证项」。

### 14. 单位标签不一致

- **位置**：`Sources/MoleWidgetCore/Formatting/Fmt.swift:31,61,72`
- **现象**：速率格式化按 1048576 除（二进制 MB）却标注 "MB/s"，比十进制 MB 高约 4.9%；`gigabytes` 同理。
- **触发条件**：所有速率与容量显示。
- **修法方向**：改标签为 MiB/s，或改用十进制换算。倾向改标签，改算法会牵动历史数据解读。

### 15. 全部重采集在主线程同步执行

- **位置**：`Sources/MoleWidgetCore/Store/MetricsStore.swift:6,76`
- **现象**：`MetricsStore` 标注 `@MainActor`，Timer 回调为 `Task { @MainActor in ... }`，无任何后台线程。数据竞争风险为零，但进程采集约 10 ms（`README.md:194`）直接压在 SwiftUI 渲染与菜单交互上，每 5 秒一次。`README.md:198` 声称的「总开销 < 1% CPU」是均值口径，掩盖了主线程上的周期性卡顿。
- **附带问题**：同文件 `:88-142` 的 `refreshFast()` 将四路采集串行执行于同一函数，单路卡住会推迟同组其余采集。速率计算使用真实墙钟间隔（`:111,124`），不会因此算错数值。
- **修法方向**：把阻塞型采集移到后台 actor，主线程只做赋值。

### 16. 在职累计依赖可选的入职日期

- **位置**：`Sources/MoleWidgetCore/Salary/SalaryEngine.swift:295,319-341`
- **现象**：`settings.hireDate` 默认 nil，此时「在职累计」直接返回 0。入职当月从 hireDate 起算，整月按满月计。
- **附带问题**：`totalEarned` 按入职月逐月循环，每轮调用 `monthWorkdays` 逐日 `isWorkday`（`Salary/ChineseWorkdayCalendar.swift:148`，每次做一次 `String(format:)` 拼 key）。`Salary/SalaryManager.swift:25-27` 注释称「重算开销很小」，与入职 10 年时每秒重复上万次日期格式化的实现不符。加班完全不处理：`nowSec >= outSec` 直接锁定当日为日薪（`SalaryEngine.swift:133-147`）。
- **修法方向**：`totalEarned` 按月预计算并缓存；`hireDate` 为空时在 UI 上说明该指标不可用，而不是显示 0。

### 17. MiniMax 请求失败会覆盖上一次成功数据

- **位置**：`Sources/MoleWidgetCore/MiniMax/MinimaxManager.swift:88-90`
- **现象**：任何一次失败都用 `MinimaxSnapshot(error:)` 整体覆盖 snapshot，短暂网络抖动会让已获取的用量数字与倒计时一并消失。
- **附带问题**：错误区分不足。仅 HTTP 401/403 映射为「认证已过期」（`MiniMax/MinimaxClient.swift:56-58`），超时、断网、DNS 失败走兜底 catch 显示英文系统文案，且与认证失败共用同一个 `error: String?` 字段，UI 只能靠文案区分。
- **修法方向**：失败时保留上一次成功数据并标记为过期；把 `error: String?` 改为可枚举的错误类型。

### 18. 截图会话取消路径未接入

- **位置**：`Sources/MoleWidgetCore/Screenshot/Capture/CaptureController.swift:212`
- **现象**：`cancelActiveSession(reason:)` 除定义处外全项目零调用。注释承诺处理睡眠/锁屏/拔显示器，实际未接。合盖或拔屏时不取消会话，靠 `topologyChanged`（`Screenshot/Capture/CapturePipeline.swift:320`）兜底，睡眠路径完全未接。
- **触发条件**：截图会话进行中合盖、锁屏或插拔显示器。
- **修法方向**：接入 `NSWorkspace` 的睡眠与唤醒通知，以及显示器拓扑变化通知。

### 19. 主线程执行 PNG 编码

- **位置**：`Sources/MoleWidgetCore/Screenshot/Capture/CapturePipeline.swift:524`
- **现象**：`clipboardOnlyDelivery` 标注 `@MainActor`，NSImage → TIFF → PNG 编码全在主线程。5K 屏可能卡 300-600 ms，且该路径为 ⌘2 直出（用户感知最强的路径）。编辑器路径因经过 actor hop 无此问题。
- **触发条件**：5K/6K 屏上用 ⌘2 截图并直接复制。
- **修法方向**：编码移到后台线程，回主线程后写 NSPasteboard。

### 20. 权限快照不会自动刷新

- **位置**：`Sources/MoleWidgetCore/Screenshot/Settings/ScreenshotSettingsView.swift:128`
- **现象**：权限状态刷新仅在设置窗口 onAppear 时触发。用户前往系统设置完成授权后返回应用，快照不自动更新，需手动重开设置窗口。授权被撤销时热键侧有订阅会重注册（`Hotkey/GlobalShortcutService.swift:862-872`，仅识别转 authorized 的方向），但截图流程侧零感知。
- **触发条件**：在系统设置中改动授权状态后返回应用。
- **修法方向**：应用回到前台时刷新权限快照，并同时处理 authorized 与 denied 两个方向。

### 21. README 与代码不一致：标注工具数量

- **位置**：`README.md:53` 与 `Sources/MoleWidgetCore/Screenshot/Editor/EditorState.swift:21`
- **现象**：README 列出「箭头 / 矩形 / 圆 / 线条 / 文字 / 马赛克 / 自由笔」共 7 项并称 8 个工具（含颜色选择器）。实际 `EditorTool` 只有 6 个 case：`rectangle, ellipse, arrow, pencil, mosaic, text`，没有独立的线条工具，直线由 `pencil` 绘制。
- **修法方向**：以代码为准修订 README 措辞与计数。

### 22. 高 DPI 大尺寸图像无上限保护

- **位置**：`Sources/MoleWidgetCore/Cursor/CursorThemeService.swift:329-346`
- **现象**：`makeStrip` 只限制帧数不限制图像尺寸，超大 DIB 会在主线程分配相应大小的 `CGContext`。
- **触发条件**：尺寸异常的 `.ani` 主题文件。
- **修法方向**：解码后按宽高上限缩放，超限时跳过该帧。

### 23. 死代码与已知限制

- **位置与现象**：
  - `Sources/MoleWidgetCore/Screenshot/Capture/CaptureController.swift:212` 的 `cancelActiveSession` 无调用方（同第 18 条）。
  - 终端（Terminal / iTerm2）文字光标不生效，catalog 已注册该名字（`Cursor/CursorThemeService.swift:93`），限制记录于 `CURSOR.md:135-139`。
  - `MiniMaxTranslationClient.swift` 的 `frameDuration` 按 `CGFloat` 声明、`remains_time` 按毫秒除 1000（`MiniMax/MinimaxTypes.swift:79`），两者依赖真实系统行为，未实机验证。
- **修法方向**：前两条按对应条目处理；第三条见「待验证项」。

---

## 已核实为正常

以下部分经审查确认实现正确，记录在此以免后续重复排查。

- **采集器 delta 计算与回绕保护**：CPU 用无符号减法 `&-` 防回绕并 `min(1.0,…)` 夹紧（`CPU/CPUUsage.swift:6,9`），首次采样只填基线不出数（`Store/MetricsStore.swift:90-99`）。
- **进程 Top 3 口径**：分母为单核，与活动监视器 `top` 口径一致（`Processes/ProcessMath.swift:40`）。
- **磁盘 I/O 单位换算**：`Disk/DiskIO.swift:18-19` 换算无误，带回绕保护。
- **全局快捷键无泄漏**：`GlobalShortcutService.stop():197` 会将 paused 条目放回 active 表统一注销，deinit 有 8 条断言兜底（`:511-530`）。
- **截图多屏并发**：并发上限 3、主屏优先、AppKit frame 与 SCK contentRect 做 0.5 pt 容差校验（`Screenshot/Capture/CapturePipeline.swift:236,282,320`）。
- **撤销/重做**：双栈实现，commit 时清空 redo 栈（`Screenshot/Editor/EditorState.swift:208-209,266`）。
- **测试覆盖**：206 个 `@Test`、18 个测试文件，覆盖全部采集器、格式化、工资引擎、快捷键。
- **桌面浮窗层级**：选在 Finder 桌面图标窗口之上、普通窗口之下，避开了 Finder 透明全屏窗口吞点击的问题（`MoleWidgetApp.swift:384`，含解释性注释）。

---

## 待验证项

以下几条静态审查无法定论，需要实机确认。

| 项目 | 需要确认什么 | 相关条目 |
| --- | --- | --- |
| 内存口径实际差值 | Vitals 的 used 与活动监视器 App Memory 在真实负载下的差值量级 | 第 13 条 |
| SMC 传感器实际数量 | `discoverCPUKeys()` 在本机枚举到的传感器个数，以及 `median > 110` 阈值是否合理 | 第 9 条 |
| 私有 API 行为兼容性 | 9 个 CGS 符号在当前 macOS 版本上的签名与行为是否与预期一致 | 第 6、7、23 条 |
| `remains_time` 单位 | 服务端返回的毫秒值除 1000 后与倒计时显示是否吻合 | 第 23 条 |
| 跨午夜班次 | 凌晨下班的设置在实机上的实际表现 | 第 5 条 |