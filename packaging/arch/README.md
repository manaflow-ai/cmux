# Arch / Omarchy packaging

This package targets Omarchy and other Arch Linux systems.

## Build dependencies

```bash
sudo pacman -S --needed base-devel cargo git gtk4 libadwaita vte4 pkgconf
```

## Build and install locally

```bash
cd packaging/arch
makepkg -si
```

The package installs:

- `/usr/bin/cmux`
- `cmux.desktop` under the FreeDesktop application directory
- a scalable `cmux` icon under the hicolor icon theme

## Omarchy install flow

Once published to the AUR, Omarchy users should be able to install it with:

```bash
omarchy pkg aur add cmux-git
```

## Runtime notes

The Linux port uses GTK4/libadwaita for the shell and VTE for PTY-backed
terminal sessions. Agent launch entries currently cover shell, Claude, and
Codex commands and expect those tools to be installed on the user's `PATH`.
