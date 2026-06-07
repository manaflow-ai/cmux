# Random Terminal Panel Backgrounds Design

## Goal

Add an opt-in setting that gives each terminal panel/surface a stable random background color, so split layouts can be visually distinguished without shell startup hacks.

## Decision

Build this as a small upstream feature on top of cmux's native terminal background plumbing. The feature should live near `Workspace Colors` because it reuses that palette, but the setting must be named as terminal panel behavior, not workspace tab behavior.

Recommended setting label:

`Randomize Terminal Panel Backgrounds`

Recommended config path:

`workspaceColors.randomizeTerminalPanelBackgrounds`

Default:

`false`

## User-Facing Behavior

When the setting is off, cmux behaves exactly as it does today.

When the setting is on:

- Each newly created terminal surface gets one stable background color.
- The color is chosen from the workspace color palette, using a softened/tinted variant suitable for terminal backgrounds.
- The color stays stable for that surface across workspace switches, pane focus changes, app session restore, and tab/surface moves.
- Browser, markdown, diff, file-preview, and non-terminal surfaces are not affected.
- Existing explicit terminal background overrides take precedence. If a process emits OSC 11, that OSC 11 color wins over the randomized panel color until the override is cleared.
- Global Ghostty theme background remains the fallback for terminal surfaces that do not have a randomized color or explicit OSC 11 override.

## Non-Goals

- Do not implement this with shell-side ANSI cell painting.
- Do not make the whole workspace one random color.
- Do not randomize workspace tab/sidebar colors.
- Do not override explicit production/safety cues emitted by shells, SSH wrappers, or terminal applications through OSC 11.
- Do not create a new theme file per panel.

## Architecture

The feature should use cmux-owned terminal surface state, not terminal output. Each terminal surface needs an optional randomized background color stored with the surface/session model.

The rendering path should treat randomized panel background as a surface-local background source below explicit OSC 11:

1. Explicit OSC 11 background override, if present.
2. Randomized terminal panel background, if enabled and assigned.
3. Workspace theme background, if a workspace theme override exists.
4. Global Ghostty theme background.

This keeps the feature compatible with the current `TerminalSurfaceBackgroundFillPlan` approach on `main`, where pane-local surface fills are applied to the host layer rather than through the shared window backdrop.

## Settings Model

Add a boolean setting:

```json
{
  "workspaceColors": {
    "randomizeTerminalPanelBackgrounds": false
  }
}
```

`workspaceColors` is acceptable as the config section because the feature uses the workspace color palette, but the setting text and schema description must say terminal panel backgrounds.

Settings UI placement:

- Section: `Workspace Colors`
- Subsection: `Terminal Panel Backgrounds`
- Control: Toggle named `Randomize Terminal Panel Backgrounds`
- Help text: `Assign a stable palette color to each terminal panel. Explicit terminal background changes still take priority.`

## Color Selection

Use the existing `WorkspaceTabColorSettings.palette()` as the source palette. Convert each palette color to a terminal-background-safe color before applying it.

The conversion should be deterministic and light/dark aware:

- In light appearance, mix the palette color heavily toward the terminal's default background or white, so text remains readable.
- In dark appearance, mix the palette color heavily toward the terminal's default background or black, so text remains readable.
- Preserve enough hue difference that adjacent panels are visually distinct.

Initial implementation can use a fixed mix ratio and reuse existing readability helpers where practical. A future setting for strength/intensity is out of scope.

## Assignment And Stability

Each terminal surface should get a stable random background token when it is first created and the feature is enabled. The assignment must not be recomputed from focus order or current layout, because those change during normal use.

Preferred state:

- Store an optional raw color hex on the terminal surface/session snapshot.
- Generate it once when a terminal surface is created without a stored value.
- Persist it with existing workspace/session persistence.

The color may be selected by cycling through the palette using existing surface order or a persisted counter. It does not need cryptographic randomness. The important property is that a user opening multiple splits gets distinct colors and those colors remain stable.

## Explicit OSC 11 Priority

cmux already tracks terminal background color changes from Ghostty action `GHOSTTY_ACTION_COLOR_CHANGE` as a surface override. The randomized background must not overwrite that override.

Implementation should distinguish:

- `terminalBackgroundOverride`: explicit runtime OSC 11 source.
- `randomizedPanelBackground`: cmux-assigned fallback source.
- theme/default background: config-derived fallback source.

If current `main` already has split source fields from workspace theme work, reuse those fields instead of adding duplicate state.

## Interaction With PR #5524

PR `#5524` adds per-workspace Ghostty theme overrides and touches the same appearance paths. This feature should be implemented as a small increment compatible with that model:

- Workspace theme chooses the default terminal appearance for the workspace.
- Random panel backgrounds choose per-terminal surface backgrounds above the workspace theme default.
- Explicit OSC 11 remains above both.

If `#5524` is merged before implementation, base this feature on `main`. If it remains open, either stack this work on top of `#5524` or wait for it to merge before opening the random panel background PR.

## Testing

Add targeted tests around behavior and persistence:

- Settings parsing accepts `workspaceColors.randomizeTerminalPanelBackgrounds`.
- Default is off.
- When enabled, a newly created terminal surface gets a randomized panel background.
- Restored sessions keep the same assigned panel background.
- Explicit OSC 11 background source takes priority over randomized background.
- Browser/non-terminal surfaces do not receive randomized terminal panel backgrounds.

Manual verification should use a tagged Debug build, not the user's production cmux app:

```bash
./scripts/reload.sh --tag random-panel-bg
```

Then launch the tagged app, enable the setting, open several terminal splits, and confirm each terminal panel has a stable distinct full-surface background.

## PR Strategy

Open a focused PR after implementation with:

- One failing-test commit for persistence/priority behavior where practical.
- One implementation commit.
- One UI/schema/localization commit if it is clearer to keep review small.

The PR description should explicitly mention that this is not a workaround for `#3799`; it depends on cmux's native host-layer background ownership. It should also mention that shell-side cell painting was rejected because it cannot color the full panel host layer.

## Open Risks

- The current release `v0.64.14` still does not show reliable full-surface per-pane backgrounds, but current `main/nightly` has newer background ownership code. Implementation must be tested against `main`, not the installed release.
- If `#5524` lands while this work is in progress, rebase and reuse its theme/source separation instead of keeping parallel appearance plumbing.
- Terminal readability can regress if palette colors are applied without enough mixing. Keep the first version conservative.
