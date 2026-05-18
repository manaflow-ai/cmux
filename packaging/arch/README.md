# Arch / Omarchy packaging

This package targets Omarchy and other Arch Linux systems.

Build and install locally:

```bash
cd packaging/arch
makepkg -si
```

Once published to the AUR, Omarchy users should be able to install it with:

```bash
omarchy pkg aur add cmux-git
```

The package currently builds the Rust GTK Linux port skeleton. It should be updated as the Linux port gains the VTE terminal backend, persistence, and agent integrations.
