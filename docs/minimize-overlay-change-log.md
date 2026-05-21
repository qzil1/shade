# 最小化窗口与蒙版行为修改记录

本文档记录本轮从最初问题到当前版本的整体修改过程、已经回退的尝试、最终保留下来的实现，以及后续回撤方式。

## 初始问题

项目是一个 macOS 菜单栏应用 `Shade`，核心功能是给非当前活跃窗口区域加蒙版，并在当前活跃窗口区域挖洞。

最初暴露的问题主要有两个：

1. 点击当前活跃窗口的黄色最小化按钮时，蒙版没有在最小化开始时立刻关闭。
2. 最小化其他非活跃窗口时，蒙版会闪烁；在同一个 app 有多个窗口时，还出现过最小化非聚焦窗口导致当前活跃窗口蒙版消失的问题。

## 中途尝试过但已经回退的改动

修复过程中曾经尝试过一些更激进的方案，但它们引入了额外问题，最后已经全部从源码中移除：

1. 添加诊断日志文件 `DiagnosticLog.swift`，记录 AX 通知、鼠标事件、窗口状态变化等。
2. 在 `WindowWatcher` 中加入更复杂的 focused window 跟踪、非活跃窗口最小化 grace period、鼠标事件 tap、`CGEventTap` 等逻辑。
3. 在 `OverlayManager` / `OverlayWindow` 中加入额外的遮罩抑制状态，例如 `keepMaskVisible`、`shouldSuppressOverlayUpdates` 等。
4. 尝试区分同 app 非聚焦窗口和不同 app 非聚焦窗口的最小化行为。

这些尝试的问题是：它们扩大了状态面，导致“非聚焦窗口最小化”与“当前活跃窗口最小化”之间互相影响。后续已经把这些改动回退，源码恢复到更接近初始结构的状态。

## 当前保留下来的核心设计

当前版本只保留一个目标：当前活跃窗口被最小化时，尽快关闭蒙版；非活跃窗口不应该触发即时关闭逻辑。

实现分为两层：

1. `AXWindowMiniaturized` 通知兜底。
2. 鼠标按下黄色最小化按钮时的提前命中检测。

其中第二层是最新增加的功能，用来做到“点击黄色按钮的一瞬间”就关闭蒙版。

## 已保留修改一：即时更新信号

文件：

- `Shade/Sources/Shade/WindowWatcher.swift`
- `Shade/Sources/Shade/OverlayManager.swift`

修改内容：

1. `WindowWatcher.onChange` 从无参数闭包改成 `(_ immediate: Bool) -> Void`。
2. `OverlayManager.updateOverlays(immediate:)` 接收这个即时信号。
3. 当 `immediate == true` 时，`OverlayManager` 跳过原本用于防闪烁的 0.05 秒 debounce。
4. 当没有活跃窗口 rect 且 `immediate == true` 时，调用 `hideMask(duration: 0)`，直接关闭蒙版。

作用：

- 普通窗口变化仍然保留 debounce，继续减少 AX 抖动导致的闪烁。
- 当前活跃窗口明确最小化时，可以绕过 debounce，立刻关闭蒙版。

## 已保留修改二：记录当前活跃 AX 窗口

文件：

- `Shade/Sources/Shade/WindowWatcher.swift`

修改内容：

1. 新增 `activeWindow: AXUIElement?`。
2. 每次成功读取 `kAXFocusedWindowAttribute` 并获得窗口位置、尺寸后，记录当前 focused AX window。
3. app 切换、窗口消失、最小化检测后清空该引用。

作用：

- 后续 AX 通知或鼠标 hit-test 能够判断事件是否真的属于当前活跃窗口。
- 避免把同 app 的其他窗口或其他 app 的窗口误判成当前窗口。

## 已保留修改三：AXWindowMiniaturized 兜底

文件：

- `Shade/Sources/Shade/WindowWatcher.swift`

修改内容：

1. AX observer callback 现在会读取通知名和通知元素。
2. 当通知是 `AXWindowMiniaturized`，并且通知元素与当前记录的 `activeWindow` 相等时：
   - 清空 `activeWindowRect`
   - 清空 `activeWindow`
   - 设置 `minimizationGracePeriod`
   - 调用 `onChange?(true)`
3. 如果通知不是当前活跃窗口的最小化，则只走普通 `poll()`。

作用：

- 当系统已经发出“当前活跃窗口开始最小化”的通知时，立即关闭蒙版。
- 非当前活跃窗口最小化不会触发这条即时关闭路径。

## 已保留修改四：点击黄色按钮瞬间关闭蒙版

文件：

- `Shade/Sources/Shade/WindowWatcher.swift`

修改内容：

1. 使用 `CGEventTap` 监听更早的左键按下事件：

   ```swift
   CGEvent.tapCreate(
       tap: .cghidEventTap,
       place: .headInsertEventTap,
       options: .listenOnly,
       eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
       callback: callback,
       userInfo: selfPtr
   )
   ```

2. 鼠标按下时，通过 `AXUIElementCopyElementAtPosition` 对屏幕坐标做 AX hit-test。
3. 从命中的 AX element 沿父节点向上查找 `AXMinimizeButton`。
4. 再继续向上查找所属 `AXWindow`。
5. 只有当该 `AXWindow` 与当前记录的 `activeWindow` 相等时，才调用 `onChange?(true)` 立即关闭蒙版。

作用：

- 在系统真正完成最小化通知之前，用户鼠标按下黄色按钮的瞬间就可以关闭蒙版。
- 相比 `NSEvent.addGlobalMonitorForEvents`，`CGEventTap` 更早接近 HID 鼠标事件，避免系统已经临时聚焦被点击窗口后才回调。
- 条件非常窄：必须命中当前活跃窗口的 `AXMinimizeButton`。
- 点击其他窗口的黄色按钮、非活跃窗口、普通鼠标点击都不会触发即时关闭。

## 已保留修改五：非活跃窗口最小化的提前保护

文件：

- `Shade/Sources/Shade/WindowWatcher.swift`

修改内容：

1. 新增 `protectedActiveWindow`、`protectedActiveWindowRect`、`protectedFrontAppBundleID` 和 `nonActiveMinimizeProtectionUntil`。
2. 当 `CGEventTap` 提前发现鼠标按下命中黄色最小化按钮，但按钮所属窗口不是当前 `activeWindow` 时，记录当前活跃窗口和 rect，并进入约 0.7 秒保护期。
3. 保护期内，`poll()` 会直接恢复并保持被保护的活跃窗口 rect，不让随后出现的临时焦点变化覆盖蒙版。
4. 如果点击的是当前活跃窗口自己的黄色按钮，仍然立即清空蒙版。

作用：

- 针对“点击非焦点窗口 B 的黄色按钮时，macOS 可能先把 B 临时聚焦，再最小化，随后焦点回到 A”的事件顺序。
- 保护点前移到系统临时聚焦 B 之前，避免蒙版跟随 B 闪一下。

## 当前 git 记录

现在项目已经初始化 git，并有以下关键提交：

1. `1a5798e Baseline before minimize button hit-test`

   这是执行“点击黄色按钮瞬间关闭蒙版”之前的基线。它包含已经回退后的代码状态，以及此前保留下来的“当前活跃窗口最小化时即时关闭”的 AX 通知方案。

2. `4ace623 Close overlay on active minimize button press`

   这是 hit-test 功能提交。它只修改了 `WindowWatcher.swift`，增加鼠标按下黄色最小化按钮时的 AX hit-test 逻辑。

3. `edfd25b Preserve overlay during non-active minimize`

   这是上一轮非活跃窗口保护尝试；后来确认没有效果，已通过 revert 回退。

4. `f55d23c Preserve last stable active window during minimize`

   这是第二轮 `lastStableActiveWindow` 尝试；后来确认没有效果，已通过 revert 回退。

5. `eb860ee Use event tap before minimize focus changes`

   这是当前的 `CGEventTap` 方案。它把黄色按钮 hit-test 前移到 HID 鼠标事件阶段，并在命中非活跃窗口最小化按钮时短暂保护当前活跃窗口的蒙版状态。

## 构建与安装验证

已经执行过以下验证：

```bash
cd /Users/qizhi/AIPlayground/shade/Shade
./build.sh
codesign --verify --deep --strict /Applications/Shade.app
```

验证结果：

- `./build.sh` 编译、清理扩展属性、签名成功。
- `/Applications/Shade.app` 已覆盖安装。
- `codesign --verify --deep --strict /Applications/Shade.app` 通过。
- 当前运行进程来自 `/Applications/Shade.app/Contents/MacOS/Shade`。

## 回撤方式

只回撤“点击黄色按钮瞬间关闭蒙版”这次最新功能：

```bash
git revert 4ace623
```

直接回到执行 hit-test 功能前的基线：

```bash
git reset --hard 1a5798e
```

如果执行了 `git reset --hard 1a5798e`，还需要重新构建并覆盖安装：

```bash
cd /Users/qizhi/AIPlayground/shade/Shade
./build.sh
rm -rf /Applications/Shade.app
cp -R Shade.app /Applications/Shade.app
open /Applications/Shade.app
```

## 当前行为预期

当前版本的目标行为是：

1. 点击当前活跃窗口的黄色最小化按钮时，蒙版应在鼠标按下时立即消失。
2. 如果鼠标 hit-test 没有捕捉到，`AXWindowMiniaturized` 通知仍会作为兜底关闭蒙版。
3. 点击非活跃窗口黄色最小化按钮时，应在系统临时聚焦该窗口前保护当前活跃窗口的蒙版状态。
4. 原有普通窗口变化仍然保留 debounce，以减少 AX 瞬时状态变化造成的闪烁。
