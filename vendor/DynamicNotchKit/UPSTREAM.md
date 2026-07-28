# DynamicNotchKit vendoring

- Upstream: https://github.com/mrkai77/DynamicNotchKit
- Revision: `cd0b3e52d537db115ad3a9d89601f20e0bee8d27`
- License: MIT, Copyright (c) 2025 Kai Azim

This directory contains the complete upstream repository at the revision above,
excluding only Git metadata. cmux builds it as a local Swift package and never
downloads DynamicNotchKit at build time.

The local patches:

- remove the documentation-only `swift-docc-plugin` dependency and its remote
  pins, keeping release builds fully vendored;
- cancel the screen-parameter observation task on deinitialization and capture
  each `DynamicNotch` weakly, preventing dismissed notification panels from
  leaking;
- isolate the AppKit-backed models to the main actor, break the
  `DynamicNotchInfo` view-retain cycle, and keep `NSVisualEffectView` inputs in
  sync when SwiftUI updates the wrapper;
- expose `DynamicNotchChrome` so cmux can change shell colors, opacity, borders,
  padding, and corner radii at runtime without patching the vendored source for
  each notification style;
- add pure screen geometry, synthetic menu-bar notch sizing, compact content
  inside that synthetic notch, pointer-hover callbacks, display relocation,
  synchronous panel configuration, and status-bar-level panel behavior for
  cmux's persistent notification tray;
- allow direct compact/expanded conversion without an intermediate hidden
  state so a single panel can animate rapid notification updates.

To update, replace this directory from a reviewed upstream revision, restore
those patches, update the revision above, and retain `LICENSE`.
