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
  leaking.

To update, replace this directory from a reviewed upstream revision, restore
those patches, update the revision above, and retain `LICENSE`.
