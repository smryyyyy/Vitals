# 自定义光标主题

Vitals 内置了一套 **CatOmen Raiden** 动画光标主题（Windows 的 `.ani` 文件格式），勾选菜单栏开关即可把整个系统的鼠标指针换成雷電娘样式，包含加载等待、拖拽、缩放等全部动画状态。

本文面向两类读者：想用这个功能的人，看「怎么用」和「出问题了怎么办」；要改这块代码的维护者，看「工作原理」和「给维护者的注意事项」。不需要先读 README，本文可以独立阅读。

---

## 怎么用

1. 确认主题文件已安装到：

   ```
   ~/Library/Application Support/Vitals/Cursors/
   ```

   没装的话在项目根目录跑 `make cursors`（`make app` 和 `make install` 会自动带上这一步）。

2. 启动 Vitals，点菜单栏图标，勾选 **自定义光标**。

3. 光标立刻变成动画样式。取消勾选即恢复系统默认光标。

开关默认是**关**的。启用它会改写全局的窗口服务器光标状态，所以不会随安装自动打开，必须你手动勾。

开关定义在 `MoleWidgetCore/WidgetSettings.swift`，UserDefaults 的 key 是 `cursorThemeEnabled`。

---

## 工作原理

### 私有 CGS API

macOS 没有公开的光标主题 API。要换系统光标，只能走 CoreGraphics Server（CGS）这套私有接口，运行时用 `dlsym` 解析，符号来自 SkyLight / CoreGraphics 框架。

`Sources/MoleWidgetCore/Cursor/CGSCursorBridge.swift` 封装了 9 个符号：

| 符号 | 作用 |
| --- | --- |
| `CGSMainConnectionID` | 拿到本进程到窗口服务器的连接 ID，所有调用的第一个参数 |
| `CGSRegisterCursorWithImages` | 注册一个光标，这是核心调用 |
| `CGSSetRegisteredCursor` | 让已注册的光标立即生效 |
| `CoreCursorUnregisterAll` | 清掉本进程注册的全部自定义光标 |
| `CoreCursorSet` | 重新实例化某个系统内置光标槽位 |
| `CGSSetSystemDefinedCursor` | 切回系统光标 |
| `CGSSetDockCursorOverride` | 自定义光标是否也作用于 Dock |
| `CGSGetCursorScale` | 读当前缩放值 |
| `CGSSetCursorScale` | 写缩放值（用于强制重绘，见下） |

这些符号不在公开 SDK 里。macOS 一次更新就可能改名、改签名或直接删掉，所以全部按「尽力而为」处理：解析不到就把 `isAvailable` 报成 `false`，所有入口降级成空操作，不会崩溃。

符号查找比 `RTLD_DEFAULT` 更严一层：先用 `dlopen` 打开确定的镜像（SkyLight / HIServices）再 `dlsym`，并用 `dladdr` 校验返回地址确实落在那个镜像里。`RTLD_DEFAULT` 会搜索进程里所有已加载镜像，同名但签名不同的符号会被直接 `unsafeBitCast` 成错误的函数指针、在服务端崩溃。校验不过就当作符号不存在处理（记日志 + 整体降级），绝不调用。

实测归属（macOS 26.6.2，`dladdr` 确认）：7 个 `CGS*` 符号在 `SkyLight.framework`，`CoreCursorUnregisterAll` 和 `CoreCursorSet` 在 ApplicationServices 里的 `HIServices.framework`，**不在** SkyLight。以后加符号要把它的归属一起写进 `SymbolImage`。

### 为什么 Vitals 必须一直运行

`CGSRegisterCursorWithImages` 注册时，光标图案存在**本进程的堆内存**里，窗口服务器只拿一个指针过去用。

实测结论是：**进程退出后光标图案仍然留在屏幕上**（窗口服务器还指着那块内存，内存没被回收）。但这是危险状态：

- 指针悬空，内存一旦被别的进程复用，画面上会出现花屏或乱码。
- 睡眠唤醒、长时间内存压力之后，系统可能把已注册的光标丢掉。

所以设计上让 Vitals 常驻菜单栏，退出时显式恢复系统光标。睡眠唤醒通过 `NSWorkspace.didWakeNotification` 监听并重新注册一遍。

这没有「安装」语义，只有「当前进程持有」这一种状态。Vitals 退出时光标恢复默认，这是正确行为，不是缺陷。

### .ani 文件怎么变成一帧动画

`ANIThemeLoader.swift` 是纯数据解析层，不碰任何窗口服务器接口。它把 `.ani`（RIFF/ACON 容器）拆成有序的帧序列加热点坐标，交给 `CursorThemeService` 去注册。

解析过程有四个实际踩过的坑，代码里都标了「实测坑位，勿回退」：

1. **`nSteps` 字段不可信**。样本里 `anih.nSteps` 恒为 32，但 `seq ` 块实际只有 24 个 DWORD（96 字节）。按 32 读会越界 8 个 DWORD，读到 LIST 头，得到垃圾帧索引。**以 `seq ` 块的实际长度为准**。
2. **DIB 的 height 字段是双倍值**。32×32 的图标写 64，因为一份 DIB 里同时装了像素数据和 1bpp 的 AND mask。实际像素行数 = `abs(height) / 2`。
3. **`clrUsed` 非 0 时**像素数据起点要后移 `clrUsed * 4`。样本恒为 0，代码保留兼容。
4. **DIB 是底向上存储**的，要翻成 CGImage 的顶向下。翻转时行的位置要从**像素数据的末尾**算，不是从整个 payload 末尾算——payload 后面还跟着 AND mask，按 payload 末尾算会把 mask 字节当成图像最上面一行。

帧数上限 24（`ANIThemeLoader.maximumFrameCount`）。超出的动画按等间隔抽样降采样，保留首尾帧。宁可让动画有点顿，也不要没有光标。

当前这套主题：16 个文件，每个 32×32、24 帧、每帧 0.1 秒。

### 帧是怎么拼成一条长图的

CGS 一次只接受**一张竖向长条图**，不是逐帧图片数组。长条高度 = 帧宽 × 帧数，每帧占一格。

拼接代码在 `CursorThemeService.makeStrip`。CoreGraphics 的 y 轴向上，所以帧是从底部往上码的，第 0 帧落在最下面。

```swift
let originY = (count - 1 - index) * height
```

**这个 `* height` 不能省。** 漏掉乘号时 24 帧全部叠在长条图最底部的 24 个像素里，上面 744 行保持透明，注册照样返回成功，但光标几乎不可见（只有第 0 帧有像素，表现为「偶尔闪一下」）。排查这类问题时先量长条图高度对不对。

另外 CGS 只接受**一个** `frameDuration` 给所有帧，不能逐帧设置。所以解析出来的每帧时长在 `makeStrip` 里被折算成平均值。当前样本全是 0.1 秒，折算后数值不变。

### alpha 通道必须是 `last` 不是 `premultipliedLast`

解码器把 DIB 的 RGBA 字节原样搬进缓冲区，没有做预乘。所以构造 CGImage 时必须声明直传 alpha：

```swift
let info = CGImageAlphaInfo.last.rawValue
```

声明成 `premultipliedLast` 的话，CoreGraphics 会把已经除过 alpha 的颜色分量再解释一次，深色光标淡到近乎透明。症状和上面那个帧拼接 bug 一样：**注册成功，但画出来是空白**。

注意区分两个地方：`ANIThemeLoader.decodeDIB` 里的 `CGImage` 用 `.last`（数据源），`makeStrip` 里那个拼接用的 `CGContext` 用 `premultipliedLast`（绘制目标）。前者不能改，后者是必须的。

透明像素的处理规则是：只要某一帧**整帧** alpha 都是 0，才当成「老式 DIB 的 alpha 字节未定义」补成不透明。逐像素判断会把所有透明轮廓像素填成黑色。

### 一个文件要注册多个标识符

macOS 26 同时使用两套光标名字：现代的 `com.apple.coregraphics.*` 和旧编号的 `com.apple.cursor.N`。不同调用方请求的名字不一样——app、Dock、浏览器的选择各不相同。

只注册一个名字就会出现「注册成功但不生效」。`CursorThemeService.catalog` 里每个文件都列了多个标识符，**每个都要注册**，不是注册第一个就算覆盖了。

16 个文件合计 40 条标识符注册。catalog 里只列 macOS 真正会请求的槽位，没列的自动回落到系统光标。

`handwriting.ani` 已被移除：macOS 根本没有手写笔/触控笔的光标槽位（没有 Windows 平板模式那种东西），注册了也不会被系统请求。

### 刷新靠缩放扰动

`unregisterAll()` 加 `CoreCursorSet 0...43` 重新实例化系统光标，**不会**让窗口服务器重新绘制。服务器会继续用自己缓存的那份内容，缓存指向的内存一旦释放，画面就空了。

有效的办法是扰动缩放值再调回来：

```swift
let bump = live + 0.01
setCursorScale(connection, bump)
setCursorScale(connection, live)
```

这个来回才是触发重绘的动作，Mousecape 和 MaCursor 都用同一招。见 `CGSCursorBridge.reload(dockOverride:)`。

---

## 已知限制

### 终端的文字光标没有生效

终端（Terminal.app、iTerm2）请求的是横向变体 `com.apple.coregraphics.IBeamH`，catalog 里已经注册了它，但在 macOS 26.6.2 上实测**没有生效**——app 里的输入框变成主题样式，shell 提示符还是系统原样。

原因未查明。可能是终端走的是另一条光标请求路径。这是个已知未解决问题。

### 主题文件不能打进 .app 包

`.ani` 文件从网上下载后带 `com.apple.provenance` 扩展属性。macOS 26 给所有从网上下载的文件打这个标记。

这个属性**删不掉**。以下手段全部试过，无效：

- `xattr -d com.apple.provenance <文件>`
- `cp -X`（不复制扩展属性）
- `ditto --norsrc`
- 读出字节重新写成一个新文件

更关键的是，**含这个属性的文件无法放进已签名的 .app**，`codesign` 直接失败。

所以主题文件放在 `~/Library/Application Support/Vitals/Cursors/`，由 `make cursors` 复制过去，`make app` 不会把它打进 `Contents/Resources`。这是刻意的设计决策，不是权宜之计：留在 Application Support 同时也方便你换主题，不用重装 app。

副作用是首次安装必须跑 `make cursors`（或 `make app` / `make install`），否则目录不存在，主题状态会报「资源缺失」。

### 依赖私有 API

整套功能建立在非公开接口上。macOS 更新后：

- 某个符号消失 → 状态显示「系统 API 已变更」，其他功能不受影响。
- 符号在但行为改了 → 可能注册成功却不生效，或者画出来是空白。
- 私有 API 的行为随时可能变，**没有向后兼容承诺**，也不保证 Apple 不会在更新中封掉。

`CursorThemeService.Health` 把这些状态都显式暴露到界面上，不用让人对着默认光标猜原因：

| 状态 | 含义 |
| --- | --- |
| `off` | 未启用，或用户关掉了 |
| `active(applied:total:)` | 注册成功 |
| `apiUnavailable` | 私有 API 没了，基本都是 macOS 更新的锅 |
| `resourcesMissing` | 主题文件不在 Application Support |
| `registrationFailed(reason:)` | API 在，但注册失败，原因在 `reason` 里 |

`active` 的两个数字口径不一致：`applied` 数的是**注册成功的标识符条数**（最多 40），`total` 取的是 `catalog.count`，即**文件数**（16）。所以正常状态下界面上会显示一个大于 total 的数，这是显示口径问题，不影响光标是否生效。

---

## 调试

### 看日志

光标相关的日志都在一个 subsystem 下，两个 category：

```bash
# 实时跟踪
log stream --predicate 'subsystem == "com.somry.vitals"' --info

# 只看光标
log stream --predicate 'subsystem == "com.somry.vitals" AND (category == "Cursor.CGS" OR category == "Cursor.Theme")' --info
```

正常启用时应该看到这几类日志：

```
Cursor.Theme  Applying 16 of 16 cursor source file(s)
Cursor.Theme  Cleared system cursors; registering 16 source file(s)
Cursor.Theme    Normal Select: strip 32x768, 24 frames, duration 0.1, hotspot (1, 1)
Cursor.CGS     Registered com.apple.coregraphics.Arrow with 24 frame(s)
Cursor.CGS     Reloaded cursors (scale 1.0 → 1.01 → 1.0, dockOverride: true)
```

排查要点：

- `Cursors directory missing from the app bundle` → 跑 `make cursors`。
- `Private cursor API unavailable on this macOS build` → 系统更新改了私有符号。
- `Failed to parse XXX.ani` → 文件损坏，换一个主题文件。
- `strip 32x32` 而不是 `32x768` → 帧拼接的高度算错了。
- 日志里有 `Registered` 但屏幕上是空白 → 检查 alpha 通道声明。
- 有 `Registered` 但光标没换 → 检查标识符是不是只注册了一个名字，或者漏了 `reload` 的缩放扰动。

### 缩小范围

排查某一类光标时，可以只应用 catalog 的前 N 项，不用重新编译：

```bash
VITALS_CURSOR_LIMIT=3 ./Vitals
```

`3` 表示只注册 `Normal Select`、`alternate select`、`Text Select`。设成 `0` 或不设置就是全套。用二分法逐段试，能快速定位是哪个文件出问题。

### 恢复系统光标

任选一种：

- 菜单栏取消勾选 **自定义光标**。
- 直接退出 Vitals。
- 极端情况（界面点不动、勾选没反应）就退出进程，窗口服务器会自行恢复。

取消勾选时走的是 `CursorThemeService.stop()`：清掉所有注册 → 重新实例化系统光标槽位 `0...43` → `reload(dockOverride: false)`。三步缺一不可，尤其最后的缩放扰动，不然系统光标会停留在旧的缓存上。

### 跑测试

```bash
make test FILTER=ANI
```

`Tests/MoleWidgetCoreTests/Cursor/ANIThemeLoaderTests.swift` 覆盖了解析层：正常样本、热点坐标、帧数来自 `seq` 表而不是写死的常量、alpha 通道没被兜底规则吃掉、DIB 上下翻转、五条错误路径（非 RIFF、非 ACON、截断、无 icon 块、坏光标数据），外加尺寸上限：声称 4096×4096 的 DIB 必须在分配缓冲区**之前**被 `.imageTooLarge` 挡住（宽或高单边超限也要挡），以及阈值本身留得住真光标。

这些测试只测解析，不涉及窗口服务器注册——注册那部分没法自动化测试，只能手动验证。`CGSCursorBridge` 也**故意没有**测试：一调就真的改掉本机鼠标指针，测试环境里坏了没法自救。

### 尺寸上限（防畸形文件撑爆内存）

解析层对单帧宽高设了 `ANIThemeLoader.maximumFrameDimension = 512`。CUR 格式自身的上限是 256（每个维度只占 1 字节），但 DIB 头里的宽高是完整的 32 位字段，解码器会按 `width × height × 4` 一次性分配。一个声称 4096×4096 的坏文件就是 ~64 MB，而且分配发生在 `apply()` 的主线程上。PNG 分支另有自己的尺寸，同样要查。

`CursorThemeService.makeStrip` 还有第二道：`width × (height × frameCount)` 的总像素上限（1<<20）。单帧限制挡不住「512 宽 × 24 帧」这种组合，那还有 25 MB。当前样本是 32×768 = 24 576 像素，比上限低三个数量级。

---

## 给维护者的注意事项

改这块代码之前，下面每一条都是踩过的坑。代码里对应位置都标了「实测坑位」或「勿回退」，别顺手改回去。

**1. 不要把符号解析改回 `static let`。**
`static let` 的初始化闭包跑在 `dispatch_once` 里，而 `dlsym` 可能重入 libdispatch，进程当场崩在 "trying to lock recursively"（macOS 26.6.2 启动时实测）。`resolvedSymbols()` 故意写成手写的一次性缓存，在 `lock` 保护下查，就是为了绕开 `dispatch_once`。

**2. 锁只保护符号缓存，不跨窗口服务器调用。**
`symbolsLock` 只在 `resolvedSymbols()` 里面用。**不要**把它扩到 `register` / `reload` / `unregisterAll` 的 CGS 调用外面：CGS 调用可能无限期阻塞，主线程拿着锁时，后台调用方会卡死在 `lock()` 上，整个 UI 跟着冻住。窗口服务器调用的串行化靠主线程独占（`requireMainThread`）——本 target 里所有调用方都是 main-actor 隔离的，这是编译期事实，不是约定。

符号解析仍然要在任何锁之前完成：`resolvedSymbols()` 自己要拿 `symbolsLock`。

**2b. 每个符号都要登记它归属的镜像。**
`resolve(_:in:as:)` 用 `dlopen(具体镜像)` + `dlsym` + `dladdr` 三件套。`dladdr` 校验不过就返回 `nil`，整个 bridge 降级成空操作——这是故意的：宁可主题不生效，也不要拿一个签名不对的函数指针去调窗口服务器。加新符号时在 `SymbolImage` 里写清楚它属于 SkyLight 还是 HIServices。

**2c. `reload()` 的收尾是 `defer`，不是人肉记的。**
`CGSSetSystemDefinedCursor(conn, 0)` 是唯一能清掉服务端光标缓存的调用，也就是"注册失败后鼠标还能回来"的那一步。它在 `reload` 开头就注册成 `defer`，所以**每一条**退出路径（包括 `connection == 0`、缩放读失败、缩放扰动失败）都会先执行它。新增 early return 不需要补收尾——但也别把 `defer` 删了改成内联调用，内联版本只要漏一个 `return` 就会退化成原来的 bug。`connection == 0` 是唯一的例外，此时没有连接可用，本进程也从未注册过任何东西。

**2d. `unregisterAll()` 会重试 3 次并返回成功与否。**
它返回 `Bool`，`false` 表示回滚没成功。上层不能假设"调过了就等于还原了"：`CursorThemeService.restoreSystemCursors` 即使收到 `false` 也照样往下跑第 2、3 步（重新实例化 + 刷新），因为失败的 unregister 并不会把服务端卡住，跳过重绘才是真正让指针消失的那一步。

**3. 注册必须在主线程同步做完。**
`apply()` 绝不能丢进 `Task` 里异步跑。异步上下文拿到的 CGS 连接和窗口服务器绘制用的那个不是同一个，注册会返回成功但永远不生效。这个坑踩过一次。

注意「异步」和「延迟执行」是两回事。睡眠唤醒的重新应用用了 `DispatchQueue.main.asyncAfter(0.25s)`：它换的是**执行时机**，不是执行线程——闭包仍然跑在主线程、仍然用本进程自己的 CGS 连接，所以不违反这条。真正的雷是 `Task` 那种会换执行上下文的写法。别把 `asyncAfter` 改成 `Task`。

延迟 0.25 秒有两个作用：唤醒通知发出时窗口服务器还在恢复中，在通知回调里直接调 CGS 可能长时间等它；而且这一延迟让一串唤醒通知被合并掉一次，不会叠加多次 apply。`apply()` 自己还有 `isApplying` 重入保护，两次 apply 交叠会让一批 `register` 和另一批 `unregisterAll` 互相穿插，留下没注册的槽位——槽位没注册就是画成空白。

**4. 帧拼接的 `* height` 不能省。**
`originY = (count - 1 - index) * height`。省掉乘号 → 24 帧叠在底部 24 行 → 注册成功但光标几乎不可见。

**5. CGImage 的 alpha 必须是 `last`。**
声明成 `premultipliedLast` → 深色光标淡到近乎透明 → 注册成功但空白。`makeStrip` 里的 `CGContext` 用 `premultipliedLast` 则是对的，那是绘制目标，别一起改掉。

**6. catalog 里每个文件的标识符要全注册。**
macOS 26 混用两套命名，只注册一个会「注册成功但不生效」。

**7. 刷新必须做缩放扰动。**
`unregisterAll()` + `CoreCursorSet 0...43` 不会触发重绘。必须 `live → live + 0.01 → live`。

**8. 先解析完再碰窗口服务器。**
`apply()` 分两段：先把所有文件解析 + 拼接成 `pending`，一个都不碰窗口服务器；全部成功才开始注册。一个坏文件不能把用户搞到没有光标。同理，只要有一个标识符注册成功就保留主题；全军覆没则整体回滚到系统默认。

**9. 系统光标槽位是 `0...43`，中间有个洞。**
编号跳过 6，所以有效范围是 0 到 43，不是 0 到 42。恢复时按 0...43 全扫。

**10. 资源目录不在 bundle 里。**
`cursorResourceDirectory()` 读 `~/Library/Application Support/Vitals/Cursors/`。别想着「优化」成读 bundle 资源，`com.apple.provenance` 会让 app 签不了名。

**11. 帧数上限 24，超过是降采样不是拒绝。**

**12. 每帧时长会被折算成一个平均值。**
CGS 只吃一个 `frameDuration`。`ParsedTheme.frameDurations` 保留了解析出来的逐帧时长，但注册后就以平均值播放，别把它当成播放时序的保证。

---

## 参考

实现这套功能时，桌面上的 MaCursor 项目（`/Users/sunshuo/Desktop/MaCursor-main`，约 18.7k 行 Swift/ObjC）是主要技术参照，用的是同一套 CGS 接口。缩放扰动刷新这个技巧也是从那里学来的。

那个项目只读，不要改。

---

*本文只描述在 macOS 26.6.2 上实测过的行为。其他 macOS 版本上的表现未验证。*
