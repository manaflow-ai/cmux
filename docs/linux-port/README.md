# Linux / Omarchy Port Plan

This document tracks the plan to port cmux from the current macOS Swift/AppKit application to a Linux application that works well on Omarchy (Arch Linux + Hyprland/Wayland).

## Target stack

- Language: Rust
- UI: GTK4 + libadwaita
- Terminal: VTE initially; evaluate Ghostty/libghostty integration once its embeddable Linux API is stable enough for packaging
- Notifications: FreeDesktop notifications through `notify-rust`
- Config paths: XDG Base Directory (`~/.config/cmux`, `~/.local/share/cmux`, `~/.cache/cmux`)
- Packaging: Arch `PKGBUILD`, then AUR package, installable on Omarchy with `omarchy pkg aur add cmux`

## Why Rust + GTK4

Rust gives cmux a native, memory-safe Linux core with strong process, PTY, async, and packaging support. GTK4/libadwaita provides a native Wayland-friendly UI that fits GNOME/FreeDesktop conventions and works well under Hyprland.

## Non-goals for the first Linux milestone

- Full feature parity with the macOS application
- Reusing Swift/AppKit UI code
- Shipping an Electron shell
- Depending on private macOS APIs or Xcode

## Milestones

### M0: Repository structure and build skeleton

- Add a Rust workspace under `linux/`.
- Add a minimal GTK4/libadwaita app crate.
- Add CI checks for formatting, clippy, and build where Linux GTK dependencies are available.
- Keep macOS code untouched.

### M1: Core terminal shell

- Create a main window with vertical workspace/tab sidebar.
- Embed a terminal widget using VTE.
- Spawn the user shell through a PTY.
- Support opening multiple sessions.

### M2: Agent/session model

- Model cmux workspaces, panes, agent commands, session state, and titles in Rust.
- Persist state using XDG paths.
- Add unit tests for session state and config migration.

### M3: Notifications and agent hooks

- Implement FreeDesktop notifications.
- Port agent hook detection and status updates.
- Support Claude/Codex-style waiting-for-input notifications with context.

### M4: Omarchy packaging

- Add a real `packaging/arch/PKGBUILD`.
- Add `.desktop` file and icon installation.
- Document Omarchy install steps.
- Publish to AUR once Linux builds are usable.

### M5: Ghostty compatibility evaluation

- Continue reading Ghostty config for theme/font/color compatibility where practical.
- Evaluate replacing VTE with Ghostty/libghostty if Linux embedding is viable and distributable on Arch.

## Proposed PR sequence

1. Add this Linux/Omarchy port plan.
2. Add Rust workspace and GTK4/libadwaita app skeleton.
3. Add terminal abstraction and VTE-backed prototype.
4. Add session/workspace domain model and persistence.
5. Add notifications and agent hook service.
6. Add Arch/Omarchy packaging.
