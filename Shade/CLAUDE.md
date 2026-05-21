# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Shade is a macOS menu-bar app that dims inactive windows by overlaying a dark mask with a "hole" cut out for the active window. It is a Swift + AppKit app (no SwiftUI) built as a `.app` bundle. It is an `LSUIElement` app (no Dock icon).

## Build Commands

The project uses a custom shell script for building, **not** `swift build`:

```bash
./build.sh
```

This script:
- Compiles all Swift sources with `swiftc` directly
- Links `-framework Cocoa -framework Carbon`
- Embeds `Info.plist` into the Mach-O binary via `-sectcreate`
- **Copies** `Sources/Shade/Info.plist` into `Shade.app/Contents/Info.plist` (required for Finder icon)
- Copies `Sources/Shade/AppIcon.icns` into `Shade.app/Contents/Resources/`
- Ad-hoc signs the app with entitlements from `Shade.entitlements`

To install:
```bash
cp -R Shade.app /Applications/
open /Applications/Shade.app
```

There is a `Package.swift` but it is secondary; the canonical build is `build.sh`.

## Architecture

### Data Flow

```
WindowWatcher (poll) → OverlayManager → [OverlayWindow per screen]
                                      ↑
StatusBarController / HotKeyManager ──┘
```

### Key Components

- **`main.swift`**: Entry point. Creates `NSApplication` with `.accessory` activation policy (no Dock icon).
- **`AppDelegate`**: Orchestrates `OverlayManager`, `StatusBarController`, `HotKeyManager`, and `AccessibilityPromptWindow`. On launch, if AX permission is missing, disables the overlay manager and shows the prompt window.
- **`WindowWatcher`**: Polls every 0.05s via `AXUIElementCopyAttributeValue` to track the frontmost window's position/size. Also listens to `NSWorkspace.didActivateApplicationNotification`.
- **`OverlayManager`**: Manages one `OverlayWindow` per `NSScreen`. Converts Accessibility API coordinates (top-left origin) to AppKit coordinates (bottom-left origin) using `CGMainDisplayID()` to identify the primary display. Determines mask hole corner radius based on front app bundle ID.
- **`OverlayWindow`**: Borderless `NSWindow` at `.floating` level. Uses a single `CAShapeLayer` with `.evenOdd` fill rule: the path contains the full screen rect plus a rounded-rect hole for the active window.
- **`HotKeyManager`**: Uses Carbon `RegisterEventHotKey` for system-wide shortcuts.
- **`StatusBarController`**: Menu-bar icon `◐`. Left click toggles an `NSPopover` preferences panel; right click shows an `NSMenu`.
- **`PreferencesViewController`**: Popover content. Controls: enable mask, dim additional displays, alpha slider, animation speed slider.
- **`AccessibilityPromptWindow`**: Borderless modal window (`.modalPanel` level, above overlays) with `NSVisualEffectView` background. Notifies delegate on close so the app can re-check AX permission.

### Critical Implementation Details

**Coordinate Conversion**: The Accessibility API returns `CGRect` with a top-left origin (Y increases downward), but AppKit/`NSScreen` uses bottom-left origin. The conversion in `OverlayManager.updateOverlays()` is:
```swift
let primaryFrame = primaryScreen?.frame ?? .zero
activeRect.origin.y = primaryFrame.minY + primaryFrame.height - activeRect.origin.y - activeRect.height
```
Use `CGMainDisplayID()` (not `NSScreen.main`) to identify the primary screen, because `NSScreen.main` changes with the key window.

**Corner Radius by App**: Apple apps (`com.apple.*` bundle ID prefix) get a 24pt corner radius; third-party apps get 14pt. This is determined in `OverlayManager` and passed as `cornerRadius` to `OverlayWindow.showMask()`. It is critical that `WindowWatcher.poll()` sets `frontAppBundleID` **before** calling `onChange?()`, otherwise the old app's radius is used during window switches.

**Show/Hide Race Conditions**: `OverlayWindow.hideMask()` uses a `UUID` token + `DispatchWorkItem` to defer hiding the layer after the opacity animation completes. `showMask()` cancels any pending hide work item and immediately restores `opacity = 1` before showing. Only `opacity` is animated during hide; `path`/`fillColor` are animated during show. This prevents flicker when rapidly toggling.

**Cross-Screen Dragging**: When a window spans displays, `minVisible: CGFloat = 40` prevents showing a tiny hole sliver on a screen where the window barely overlaps.

### Global Hotkeys

Registered via Carbon `RegisterEventHotKey`:
- `Cmd+Shift+H`: Toggle dimming on/off
- `Cmd+Shift+↑`: Increase mask alpha (+0.05)
- `Cmd+Shift+↓`: Decrease mask alpha (-0.05)
- `Cmd+Shift+M`: Toggle "dim additional displays"

### App Bundle Requirements

For the app icon to display in Finder, `Shade.app/Contents/Info.plist` must exist as a standalone file (the `-sectcreate` embedding is not sufficient). `build.sh` handles this with `cp Sources/Shade/Info.plist Shade.app/Contents/Info.plist`.
