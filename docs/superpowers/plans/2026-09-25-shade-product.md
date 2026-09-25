# Shade native dimming implementation plan

**Goal:** Turn the existing Shade prototype into a dependable, polished native macOS focus utility.

**Architecture:** Prefer a non-key, click-through window ordered below the real focused window; verify server order and fall back to a conservative rectangular mask when it is unavailable. WindowServer supplies the real silhouette, shadows and movement. AX notifications supply focus changes; a low-frequency metadata refresh recovers missed events. Keep pure window selection and display policy separate from AppKit rendering.

**Tech stack:** Swift, AppKit, Accessibility, Core Graphics metadata, Carbon hotkeys, ServiceManagement on macOS 13+. No external dependencies, private APIs, screenshots or network services in the application.

## Decisions

- Retain the existing Shade identity and bundle identifier for local permission continuity.
- Remove app-specific rounded-rectangle guessing: hardcoded radii and clipped cross-screen geometry cannot accurately preserve arbitrary native shapes. Compatibility mode leaves the complete focused bounding rectangle clear.
- Use public window ordering. Validate actual WindowServer order, including windows belonging to another process, before treating the renderer as working.
- Hide safely on missing permissions, desktop/no focused window, sleep, and fullscreen focus; never leave the desktop black with an unknown target.
- Focus changes reorder immediately. Fade duration applies to enabling, disabling and intensity/color changes; window movement is handled by the compositor, without a delayed animated hole.
- Settings: saved enabled state, independent optional dark appearance profile, dim amount/color, fade duration, Fn pause, three multi-display modes, per-display exclusions, application exclusions, login item on supported systems.
- Preserve the existing global shortcut defaults. Surface registration failures. Provide menu-bar scroll and double-click.
- Build a Chinese native quick panel with a live illustrative preview and a separate settings window. Respect reduced motion and semantic system colors.

## Work and acceptance checks

- [x] Core policy and persisted preferences. Write failing cases for same-position windows, cross-screen geometry, missing/invalid windows, display modes, exclusions, and sanitized settings; run `Shade/test.sh`.
- [x] Native compositor and event-driven watcher. Validate non-key/click-through/shadow-free panel properties and actual below-target ordering. Remove private AX lookup and the move/minimize timing heuristics that caused flashes.
- [x] Product controls and lifecycle. Verify permission recovery without relaunch, shortcuts, Fn pause, appearance, login errors and persistent settings.
- [x] Packaging. A clean `Shade/build.sh` creates a complete optimized app bundle with deployment target, resources and verified signature; support optional Developer ID identity and universal architecture builds.
- [ ] Verify UI using native rendering and, if computer-use permissions permit, live app interactions. Record exactly which OS/display scenarios were tested; do not claim commercial release certification.
- [x] Update README and regression checklist. Deliver a runnable build and preserve the old installed app before replacement if installing for verification.

## Reference and limits

- Apple's public NSWindow ordering and CGWindowList metadata APIs; metadata matching uses PID and bounds, never window titles or screen capture permissions.
- Existing project evidence: `docs/minimize-overlay-change-log.md` and the current sources take precedence over historical implementation guidance.
- App Store distribution, Developer ID notarization, Focus Filters and Shortcuts integration require distinct signing/distribution work; do not represent them as implemented.

## Verification outcome

The Mac was locked. Cross-process relative ordering was inconsistent even under a real NSApplication event loop; the renderer now checks server order and uses the compatibility mask when needed. Automated checks verify that branch. Interactive QA and release certification remain pending, as recorded in `docs/release-readiness.md`. No installed application was replaced.
