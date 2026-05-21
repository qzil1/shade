# Shade - macOS 窗口专注工具

一款轻量级的 macOS 屏幕遮罩工具，自动将非活动窗口变暗，只高亮当前焦点窗口，帮助你减少视觉干扰、保持专注。

## 功能特性

- **自动背景变暗**：自动检测当前焦点窗口，其余区域自动覆盖半透明遮罩
- **平滑动画过渡**：窗口焦点切换时，遮罩区域以 200ms 平滑动画跟随移动
- **多屏幕支持**：自动识别多个显示器，每个屏幕独立计算遮罩区域
- **菜单栏控制**：通过菜单栏图标快速启用/禁用、调节遮罩强度
- **鼠标事件穿透**：遮罩层不拦截鼠标点击，完全不影响正常操作
- **轻量无打扰**：应用不在 Dock 显示，仅通过菜单栏图标控制

## 系统要求

- macOS 11.0 (Big Sur) 或更高版本
- 需要授予**辅助功能**权限（用于获取窗口位置信息）

## 快速开始

### 方式一：直接运行（开发）

```bash
cd Shade
swift run
```

### 方式二：构建 .app 应用包

```bash
cd Shade
./build.sh
open Shade.app
```

### 首次运行

首次启动时，系统会提示授予**辅助功能**权限：
1. 打开 **系统设置 > 隐私与安全 > 辅助功能**
2. 将 `Shade` 添加到列表中并勾选
3. 重新启动应用

## 使用说明

- 点击菜单栏的 **◐** 图标打开控制面板
- **启用遮罩**：开关控制整体功能的开启/关闭
- **遮罩强度**：滑块调节遮罩的不透明度（0.1 ~ 0.9）
- **退出应用**：点击退出按钮

## 项目结构

```
Shade/
├── Package.swift                    # Swift Package Manager 配置
├── build.sh                         # 构建 .app 的脚本
├── Sources/Shade/
│   ├── AppDelegate.swift            # 应用入口与生命周期
│   ├── OverlayWindow.swift          # 遮罩窗口（CAShapeLayer 挖洞实现）
│   ├── OverlayManager.swift         # 管理所有屏幕的遮罩窗口
│   ├── WindowWatcher.swift          # 监听焦点窗口变化（Accessibility API）
│   ├── StatusBarController.swift    # 菜单栏图标与 NSPopover
│   └── PreferencesViewController.swift  # 控制面板 UI
└── README.md
```

## 技术原理

1. **遮罩层实现**：为每个屏幕创建一个无边框全屏窗口，使用 `CAShapeLayer` + `evenOdd` 填充规则，在遮罩层上"挖洞"露出活动窗口区域
2. **窗口监听**：通过 macOS Accessibility API (`AXUIElement`) 轮询获取当前焦点窗口的全局坐标
3. **坐标映射**：将全局窗口坐标转换为对应屏幕的本地坐标，精确对齐遮罩洞口
4. **事件穿透**：遮罩窗口设置 `ignoresMouseEvents = true`，确保鼠标操作完全不受影响

## 许可证

MIT
