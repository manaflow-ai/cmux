# Ghostty config support roadmap (cmux)

## Current state

cmux terminal surfaces already load Ghostty config through libghostty (`ghostty_config_load_default_files`), so terminal runtime behavior follows upstream config.

For cmux-owned UI behavior, we currently read only three Ghostty keys from the live config object:

- `background`
- `background-opacity`
- `focus-follows-mouse`

Separately, `Sources/GhosttyConfig.swift` does its own file parsing for a narrow set of keys used by cmux UI/theme plumbing. This creates drift risk versus Ghostty's real parser (includes, conditional config, and future key semantics).

## Gaps to address

### 1) Window padding parity for non-terminal surfaces

Ghostty has `window-padding-x`, `window-padding-y`, `window-padding-balance`, and `window-padding-color`. cmux does not consume these keys today, so browser panels and cmux chrome do not align with terminal window padding behavior.

### 2) Cursor visibility parity

Ghostty supports `mouse-hide-while-typing`; cmux does not map this for browser/omnibar typing paths.

### 3) Window appearance parity

Ghostty exposes `window-theme`, `window-decoration`, `window-colorspace`, and `macos-titlebar-style`. cmux currently uses its own window/titlebar behavior and does not bridge these Ghostty settings.

### 4) Split behavior parity

Ghostty supports `split-preserve-zoom`; cmux split zoom/focus behavior is implemented independently in Bonsplit, without reading this key.

### 5) Subtitle parity

Ghostty supports `window-subtitle = working-directory`; cmux does not map this key into its titlebar model.

### 6) Blur parity

Ghostty supports `background-blur`; cmux currently has no config-driven mapping for browser/chrome blur.

## Proposed implementation

### Phase 1: Unify config reads through live Ghostty config

- Add `GhosttyRuntimeConfigSnapshot` in cmux that is hydrated from `ghostty_config_get` after app init/reload.
- Keep a single source of truth for UI-relevant Ghostty keys.
- Emit snapshot updates on `.ghosttyConfigDidReload` and appearance-driven reloads.

### Phase 2: Apply snapshot to cmux-owned UI

- Browser panel/container insets from `window-padding-x/y` and balancing logic.
- Browser/chrome background edge treatment from `window-padding-color`.
- Global cursor-hide behavior while typing when `mouse-hide-while-typing = true`.
- Window/titlebar adapter for `window-theme`, `window-decoration`, and `macos-titlebar-style` where platform constraints allow.

### Phase 3: Split + subtitle mapping

- Map `split-preserve-zoom` to Bonsplit zoom retention rules.
- Map `window-subtitle` to workspace subtitle policy (start with `working-directory`).

### Phase 4: Reduce parser drift

- Migrate UI-critical reads away from `GhosttyConfig.parse` to live snapshot fields.
- Keep `GhosttyConfig.swift` only for cmux-specific compatibility data that cannot be obtained from live config.

## Test plan

- Unit tests for snapshot decoding and fallback defaults (bool, enum, color, padding structs).
- Unit tests for mapper behavior (`split-preserve-zoom`, subtitle policy, cursor-hide policy).
- UI tests for:
  - browser padding parity with terminal in the same workspace
  - cursor hide/show while typing in browser omnibar and web content
  - titlebar style/theme behavior under key config permutations

## Suggested PR sequence

1. Config snapshot foundation + tests.
2. Padding + cursor-hide mapping.
3. Window appearance mapping.
4. Split preserve zoom + subtitle mapping.
5. Parser drift cleanup (`GhosttyConfig.swift` scope reduction).
