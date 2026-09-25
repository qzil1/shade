# Shade

Shade 是原生 macOS 菜单栏专注工具。让当前窗口保持清晰，把背景柔和调暗。

项目仓库名为 `shade`，Swift 工程、可执行文件和应用名称均为 `Shade`。

## 使用

需要 macOS 11+；登录时启动的内置开关需要 macOS 13+。项目不使用第三方依赖。

```bash
cd Shade
./build.sh
open Shade.app
```

如旧版 Shade 已运行，请先从菜单栏退出旧版，再打开新版；应用有单实例保护。初次运行，在“系统设置 → 隐私与安全 → 辅助功能”中允许 Shade，授权后自动恢复，无需重启。重新编译的本地签名可能需要重新授权。应用自身不申请屏幕录制权限，不截图，不保存窗口标题或内容，不联网。

当前构建产物位于 `Shade/Shade.app`。构建脚本不会自动安装或覆盖 `/Applications/Shade.app`。

## 已实现

- **窗口跟踪**：AX 焦点、移动、缩放、最小化和销毁通知，配合 0.75 秒低频恢复检查。已识别的窗口按 ID 跟踪，避免拖动时两套坐标短暂不同步而闪烁。
- **两种渲染路径**：优先尝试真实窗口下方的原生遮罩，并检查 WindowServer 的实际顺序；顺序无法保证时，自动采用保留完整活动窗口矩形的兼容遮罩。兼容路径不猜测应用圆角，不进行洞口飞行／收缩动画。
- **强度与色调**：0–90% 背景变暗，石墨、暖夜、深蓝三种色调；0–500 ms 启停及强度渐变，尊重系统“减少动态效果”。
- **浅色／深色外观**：可分别保存色调和强度，并跟随系统外观切换。
- **多显示器**：仅突出当前窗口、每屏保留前方窗口、只调暗当前屏幕；可以逐屏排除，使用稳定的显示器 UUID 保存。
- **应用排除**：指定应用在前台时自动暂停，切换后恢复。
- **快捷操作**：菜单栏滚动调强度，双击开关，右键菜单；按住 Fn 临时暂停，松开恢复。
- **完整设置保存**：启用状态、强度、色调、渐变、多屏策略、应用及显示器排除、Fn 偏好均保存。
- **运行状态**：权限、暂停、排除应用、无窗口、全屏等状态在面板中明确显示；权限状态与用户启用偏好分离。
- **生命周期**：屏幕变化重建遮罩，睡眠／会话切换清除，唤醒重新检查；退出清理窗口、监听和快捷键。

| 快捷键 | 操作 |
| --- | --- |
| ⇧⌘H | 启用／暂停 |
| ⇧⌘↑ / ⇧⌘↓ | 强度 ±5% |
| ⇧⌘M | 循环切换三种多屏策略 |
| 按住 Fn | 临时暂停（可关闭） |

快捷键保留旧版默认值，目前不能在应用内重绑定。注册冲突会显示在“快捷控制”页。

## 构建与验证

```bash
cd Shade
./test.sh                 # 25 个核心检查：策略、坐标、身份和持久化
./test.sh --integration   # AppKit/WindowServer 检查与浅色、深色 UI 离屏渲染
ARCHS='arm64 x86_64' ./build.sh  # Universal 2；默认只构建本机架构
codesign --verify --strict Shade.app
```

原生检查需要图形登录会话和至少一个普通应用窗口，会短暂显示 1% 强度的测试层，不注入输入、不修改系统权限。UI 图片输出到 `.build/qa/`，属于布局验证，并不是实机交互验收。

构建脚本先在临时目录编译并检查，成功后才替换构建产物。包含 `.app` 所需的 `Contents/MacOS`、独立 `Info.plist`、图标和签名；明确设置 macOS 11 部署目标，使用优化编译。

默认使用本地 ad-hoc 签名。已有开发者证书时可使用：

```bash
SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ARCHS='arm64 x86_64' ./build.sh
```

此命令启用 hardened runtime 和签名时间戳；**不执行 notarization 或发布**。

## 已知边界与发布状态

这是可编译、可本地运行的改进版，尚未完成商业发布验收。

- 本次机器处于锁屏状态，不能完成真实拖动、Mission Control、Spaces、全屏、多物理显示器及权限授权的交互验证。
- 当前会话的跨应用原生排序不稳定，原生测试实际验证了兼容遮罩分支，不能宣称原生剪影／阴影已在用户桌面上验收。兼容路径使用矩形边界，圆角外侧可能有少量背景透出；极快拖动仍需实机评估。
- 原生排序路径保留系统浮动工具面板的层级；不同应用的面板、透明窗口和系统特殊窗口需要按验收矩阵检查。
- 尚未实现 Focus Filters、Shortcuts/AppleScript、自定义快捷键录制、自动更新、商业授权与付费体系。
- Universal 2 已交叉编译；旧版 macOS 和 Intel 实机兼容性不能由当前系统上的编译结果代替。
- 未进行长期 CPU／内存／耗电基准，不能宣称已满足早期需求文档中的性能目标。

详见 [验收记录与检查清单](docs/release-readiness.md)。

## 结构

```text
Shade/
  Sources/Shade/
    DimmingPolicy.swift             # 纯窗口选择、多屏策略、坐标模型
    ShadeSettings.swift             # 持久化和外观配置
    WindowWatcher.swift             # AX/Workspace 事件、低频恢复检查
    OverlayManager.swift            # 状态、显示器、渲染调度
    OverlayWindow.swift             # 原生排序及保守兼容遮罩
    PreferencesViewController.swift # 菜单栏快速面板与效果示意
    SettingsWindowController.swift  # 通用、显示器、应用排除、快捷控制
    SystemSupport.swift             # 权限入口和系统登录项
    StatusBarController.swift       # 菜单栏、滚动、双击和右键菜单
    HotKeyManager.swift             # Carbon 快捷键与失败反馈
  Tests/                            # 核心及原生检查
  build.sh                          # 优化编译、Universal 2、签名
  test.sh
```

## 许可证

本仓库目前未指定开源许可证。
