# `embedder/` — fork-bound artifacts

> **NOTE — the `BUILD.gn` files pass `gn format` against the M148 tree
> on `cmux-aws-mac`** (both files round-trip cleanly through the
> depot_tools `gn format` parser; the only diffs are GN's single-line
> collapses for length-1 lists, which have been applied here). They
> have **not yet been `gn gen`-ed against a real `cmux_core_framework`
> dep graph** (the framework is not yet reachable from
> `//chrome:gn_all`), so semantic checks like target-lookup,
> source-file existence beyond this directory, and template arg
> types are still unverified. The obvious bugs the earlier WARNING
> called out are fixed:
>
> - `BUILD.gn` no longer lists `cmux_browser.mm` / `cmux_view.cc` /
>   `cmux_session.cc` / `cmux_profile.cc` / `cmux_layer_host.mm` in
>   `sources` — those files don't exist yet, so `gn gen` would have
>   failed at "source file does not exist". They are left as a
>   commented-out TODO block, to be re-enabled per file as each
>   implementation lands.
> - `cmux_BUILD.gn` no longer reads `helper[3]`/`[4]`/`[5]` (the
>   `content_mac_helpers` tuple is 3-wide; indices 3+ would have
>   tripped GN's bounds check). The `foreach` body now indexes
>   `helper_params[0..2]` exactly like upstream
>   `chrome/BUILD.gn:826`, the helper-target naming matches
>   what the foreach generates, and the `group("cmux_helpers")`
>   target list is generated from the same `content_mac_helpers`
>   list so the names cannot drift.
> - The helper template is inlined as `template("cmux_helper_app")`,
>   mirroring `chrome_helper_app` in `chrome/BUILD.gn:730`. Empty
>   placeholder sources (`cmux_helper_main_mac.cc`,
>   `cmux_framework_main.cc`) are referenced where mac_app_bundle /
>   mac_framework_bundle require non-empty source lists; those files
>   need to land in `//cmux/embedder/` before the first `gn gen`.
>
> The `.h` header, branding plists, README, and CHANGELOG remain
> accurate as-is. First real validation happens when the fork repo
> exists and these files drop into `src/cmux/`, at which point a
> `gn check //cmux/...` will surface any remaining issues.


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
