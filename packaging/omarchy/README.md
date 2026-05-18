# cmux for Omarchy / Arch Linux

This directory is a packaging scaffold for Omarchy (Arch Linux + Hyprland).

## Current status

`cmux` cannot currently be packaged as a runnable Omarchy/Arch Linux app because the upstream application is macOS-only:

- Swift sources import `AppKit`, `SwiftUI`, and `Darwin`.
- The project is built with `cmux.xcodeproj` / Xcode.
- The app uses macOS entitlements and macOS-specific integrations.
- There is no Linux build target or Linux release artifact.

Because of that, a normal `PKGBUILD` cannot produce a working Linux package yet. The Linux port needs to land before Omarchy packaging can be completed.

## Proposed Omarchy package shape after Linux support exists

Once cmux has a Linux target, package it as an Arch package with:

- executable installed to `/usr/bin/cmux`
- desktop file installed to `/usr/share/applications/cmux.desktop`
- icon installed under `/usr/share/icons/hicolor/.../apps/cmux.png` or SVG equivalent
- runtime dependencies declared in `depends=()`
- build dependencies declared in `makedepends=()`

Omarchy users would then install it with one of:

```bash
makepkg -si
# or, if published to AUR:
omarchy pkg aur add cmux
```

## Porting checklist

1. Add a Linux build target separate from the macOS AppKit target.
2. Replace AppKit-only UI/windowing code with a Linux-capable UI stack.
3. Replace macOS notification/keychain/menu-bar integrations with Linux/FreeDesktop equivalents.
4. Replace Darwin-only process, PTY, and socket calls with portable Foundation/Glibc code where possible.
5. Verify Ghostty/libghostty availability and linking on Arch Linux.
6. Add a real `packaging/omarchy/PKGBUILD` once a Linux binary can be built.
