# Shade development guide

Shade is a native Swift/AppKit menu-bar focus utility. Read the repository README and `docs/release-readiness.md` for current behavior and limitations. `docs/minimize-overlay-change-log.md` describes historical implementation, not the present architecture.

## Commands

- Canonical bundle build: `./build.sh` in this directory.
- Core checks: `./test.sh`.
- AppKit checks/layout renders: `./test.sh --integration` in a graphical user session.
- Universal build: `ARCHS='arm64 x86_64' ./build.sh`.
- `SIGN_IDENTITY` optionally selects a Developer ID identity; the default is ad-hoc local signing.
- Swift Package Manager is secondary. Do not install or overwrite the existing application merely to compile.

## Design constraints

- `WindowWatcher` listens to AX and Workspace notifications; the 0.75 s timer is a recovery watchdog.
- Window identity is not geometry. Reuse the resolved CG ID while the focused AX element stays equal. Do not infer minimizing from a change in window size.
- Read metadata only. No window titles, screenshots, screen-capture permissions or private `AXUIElementGetWindow`/CGS calls.
- AX/Quartz coordinates have a top-left origin anchored to the primary display. AppKit screen coordinates have a bottom-left origin. Use `CGMainDisplayID()` to locate the primary display; `NSScreen.main` changes with focus.
- Try native relative ordering and validate actual server order. If the target order cannot be guaranteed, keep the active window's full rectangle transparent in the compatibility renderer. Never draw a full opaque mask above the active window.
- Compatibility paths are immediate and unanimated. Do not clip the rectangle to a screen and then round it; that creates false corners at display boundaries.
- Use generation-protected fade cleanup; quick hide/show must not let an old completion hide a new mask.
- Runtime permission and suspension state must not overwrite the persisted enabled preference.
- Keep overlays non-key, click-through, without shadows or Dock presence. Clean up listeners and timers on stop.
- Settings changes must update the quick panel and displayed mode, including changes made through shortcuts.
- Respect reduced motion and do not register a login item until the user operates the login control.

## Verification honesty

A locked session cannot validate interactive dragging, Spaces, Mission Control, permission-grant recovery or physical multi-display behavior. Integration checks explicitly report whether native ordering or the compatibility path was exercised. Do not claim commercial release readiness from a successful build alone.
