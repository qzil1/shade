# Shade naming migration implementation plan

> Execute in the current session; the existing upload agent owns GitHub operations while the parent owns local changes.

**Goal:** Use `shade` for the repository and canonical checkout, and `Shade` for the application and its project directory.

**Architecture:** Rename packaging paths and project documentation without changing application behavior or the existing bundle identifier. Repair the linked worktree after moving the main checkout.

**Tech Stack:** Swift, AppKit, Git, Markdown, GitHub.

## Steps

- [x] Rename the application project directory to `Shade/`; update `.gitignore`, README build commands, and paths in the existing documentation.
- [x] Present the requirements and README as Shade's own project documents.
- [x] Move the canonical checkout to `/Users/qizhi/AIPlayground/shade`, leave a compatibility symlink for existing local task paths, and run `git worktree repair`.
- [x] Run `Shade/test.sh`, a temporary-copy `Shade/build.sh`, `git diff --check`, and naming/path checks. Verify that tracked Swift files, the application icon, and `Info.plist` are byte-identical across the directory move. Do not install or restart the application.

## Verification on 2026-09-26

- All 25 core checks passed after the directory move.
- A clean temporary-copy arm64 build, Info.plist validation, and strict ad-hoc signature verification passed. No installed or existing local app bundle was replaced.
- All 22 tracked files inside the moved project directory are byte-identical to the pre-migration commit, including source, tests, scripts, configuration, and icon.
- The application and its current project paths use Shade consistently; generated app/build directories remain ignored.
- GitHub upload is handled separately by the existing upload agent; its result must be verified against the committed migration.

## Scope and evidence

The migration preserves application behavior and its existing bundle identifier. It does not add a license or change the release acceptance criteria.
