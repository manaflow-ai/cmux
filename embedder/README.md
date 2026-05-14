# `embedder/` — fork-bound artifacts

This directory is the staging area for files that will eventually live
under `//cmux/embedder/` in the **manaflow-ai/cmux-chromium** fork.

The fork repo does not exist yet — it needs user permission to create
an org-level repo. Until then, the canonical copies live here so:

1. Review is unblocked: the C ABI is a real header, not a sketch
   embedded in a markdown file.
2. The moment the fork repo lands, contents drop in with no extra
   editorial work.
3. If anything changes in the Swift wrapper's expectations
   (`Packages/CmuxBrowserEngine/`), the corresponding ABI change is
   tracked in this directory's git history.

## Contents

- `cmux_browser.h` — the C ABI exported from `CmuxCore.framework`.
  Source of truth for `CmuxBrowserEngine`'s `ChromiumBrowserBackend`.
  Lands at `src/cmux/embedder/cmux_browser.h` in the fork.
- `BUILD.gn` — GN target wiring for `//cmux/embedder:embedder` and
  `//cmux/embedder:embedder_headers`. Lands at
  `src/cmux/embedder/BUILD.gn` in the fork.
- `cmux_BUILD.gn` — GN target wiring for `//cmux:cmux_core_framework`
  itself (mac_framework_bundle) plus the four helpers
  (renderer/gpu/plugin/main). Lands at `src/cmux/BUILD.gn` in the
  fork (note the renamed-for-disambiguation prefix only matters
  here; the file's contents are the parent BUILD).
- `CHANGELOG.md` — ABI version history. Bump
  `CMUX_EMBEDDER_ABI_VERSION` on any breaking change.
- `branding/cmux_core_framework-Info.plist` — Info.plist template for
  `CmuxCore.framework`. Lands at `src/cmux/branding/`.
- `branding/cmux_helper-Info.plist` — Info.plist template for the four
  helpers (main/renderer/gpu/plugin); per-helper substitutions come
  from `//cmux/BUILD.gn`. Lands at `src/cmux/branding/`.

## How this maps to the fork

When the fork repo is created from M148 base, the layout is:

```
manaflow-ai/cmux-chromium/
└── src/
    └── cmux/
        ├── BUILD.gn                    # cmux_core_framework target
        └── embedder/
            ├── BUILD.gn                # ← embedder/BUILD.gn from here
            ├── CHANGELOG.md            # ← embedder/CHANGELOG.md from here
            ├── cmux_browser.h          # ← embedder/cmux_browser.h from here
            ├── cmux_browser.mm         # Obj-C++ glue (P1)
            ├── cmux_view.cc            # WebContentsDelegate (P1)
            ├── cmux_session.cc         # session lifecycle (P1)
            ├── cmux_profile.cc         # BrowserContext wrappers (P1)
            └── cmux_layer_host.mm      # CAContext/CALayerHost (P2)
```

The `.cc`/`.mm` files are not staged here because they are
implementation, not interface, and implementing them in advance of
the fork's content layer toolchain would just rot. Once the fork
builds an empty `cmux_core_framework`, those files land directly in
the fork.

## Versioning policy

`CMUX_EMBEDDER_ABI_VERSION` starts at `1`. Bumps:

- **Major**: any function signature change, struct layout change,
  enum value semantic change. Old framework with new package, or
  vice versa, fails to load with `CMUX_E_ABI_MISMATCH`.
- **Additive**: new function at end of header. Use
  `dlsym`/weak-link from the Swift side to detect.

The package's `CmuxBrowserEngine.swift` pins
`CMUX_EMBEDDER_MIN_ABI` and `CMUX_EMBEDDER_MAX_ABI`. The framework's
load-time assertion is the only ABI gate.
