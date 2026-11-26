# Customization API: behavior and motion gaps

Leo, 2026-11-25: "but not only look. we want those repos to also have the feature sets and animations" and
"aka improve our apis and sdks and whatnot and have good docs for agents and good copy-paste prompts for agents".

This page lists what an extension or a customization profile (claude-code-app, codex-app, t3-code,
web-coding-app) can express today beyond its look: commands, keybindings, panel flows, panes with state,
and motion. It was audited on `feat-cmux-next` at 7b0e563e2ee4 against `cmux-tui/crates/cmux-app-host`
(interfaces/, js/ABI.md, generated/cmux-app.d.ts), `cmux-extension-sdk`, `cmux-customize` and
`cmux-app-manifest`. Every row is either expressible now or names the missing piece. A gap found by
the profiles lane goes here first, then into a PR.

## Motion

| Surface | Expressible today? | Missing piece |
| --- | --- | --- |
| A prop change animates (spring, timed curve, design-token springs) | Yes: `.animation(m)`, runtime 1.4.0, web and native renderers | Done here: one Rust contract `cmux.motion/1` (`cmux-app-host/src/motion.rs`, `cmux_extension_sdk::motion`) normalizes it on every batch, so both renderers read the same value |
| Enter and exit transitions of a node | Yes: `.transition(opacity slide scale move pop)` | Done here: `.transition({kind, motion})` times the move and fade with a motion token, spring or timed curve on both renderers; `cmux.motion/1` sends a transition without a motion as the bare kind, so it keeps the renderer's own springs |
| Looping effects (pulse, breathe, spin, ...) | Yes: `.loop({effect, period, amount})` | None: the native renderer clamps `amount` to [-10, 10] like `cmux.motion/1`, so a negative `spin` turns counterclockwise on macOS too |
| Particles and choreographed glyphs | Yes: `Particles({preset})`, `cmux.particles/1` (validated in Rust) | None found |
| Named motion presets shared by an app's nodes | Partly: the look carries them (a theme file's `motion.presets`, `{duration, bounce}` springs read and clamped in Rust by `cmux_extension_sdk::motion_profile`); an extension still passes a JS constant to `.animation()` | `.animation("presetName")` does not resolve a look preset yet: each app host runs in its own process and does not read the active look. `MotionProfile::preset_animation` already gives a preset's `cmux.motion/1` spring for that step |
| Chrome motion (tab reflow, sidebar, palette, hover card) | Partly: a theme file's `motion.springs` and `motion.fades` override the design-token springs and fades by name; the daemon reads, checks and clamps them and `theme.slots.resolve` answers them with the slots on every theme file change | The macOS app does not apply the answer yet: its chrome still reads the compiled-in `MotionTunables` defaults. The next step is a Swift layer that applies the answer's `motion` under the Debug Settings overrides |
| Streaming style of agent text (reveal, cursor, chunk fade) | No: only `agentPane.display.thinking.glyph` and `transcriptLook` | No `agentPane.display.streaming` setting (reveal per token, per line or instant, and its fade). Every web-coding-app profile needs one |
| Scroll and gesture motion inside a pane scene | No | No scroll-linked props: an extension cannot pin a header or fade content against its scroll position |

## Behavior

| Surface | Expressible today? | Missing piece |
| --- | --- | --- |
| Palette commands | Yes: `cmux.palette.scope/1` and the action catalog (`action.run`) | None found |
| Slash commands in the composer | Yes: `cmux.composer.command/1`, from the manifest alone | None found |
| Keybindings an extension declares | Yes: `contributes.keybindings` in keybindings.json form (`{key, command, when?, args?}`, the same parser), an own op or a cmux action, in the app binding layer below the person's keybindings.json; a pair bound twice warns (`keybindings.shortcutConflict`) | Bare keys outside a bare-key `when` stay the person's |
| Menus and toolbar items | Yes: `contributes.menus`, `contributes.toolbarItems` | None found |
| Panes and overlays | Yes: `cmux.pane/1` (`presentation.overlay` too), `cmux.section/1`, `cmux.newtab/1`; panel flows: `cmux.app.openPane(args)` resolves the pane's `ctx.close(result)`, and the pane context has `args`, `onOpen` and `onClose` (runtime 1.5.0) | None for the flow itself |
| Pane state that survives a reload | Yes: `ctx.keep(name, initial)` on every view context, a signal the daemon keeps with the mount through a `cmux ext dev` save, a host restart or a Reload, and `ctx.state` (runtime 1.6.0); `app.storage.*` for what outlives the view | Scroll position and focus are the renderer's, not kept yet |
| Composer layout (toolbar, chips, model and reasoning picker) | Yes: `cmux.composer.toolbar/1`, `cmux.composer.chip/1`, `cmux.composer.model.picker/1` | None found |
| Chat message actions and widgets | Yes: `cmux.chat.action/1`, `cmux.chat.widget/1` | None found |
| Hover cards and sidebar row decorations | Yes: `cmux.hovercard/1`, `cmux.sidebar.rows/1` | `cmux.sidebar.rows/1.json` was not valid JSON (unescaped quotes in `docs`), so its options schema did not load. Fixed in the same PR as `cmux.motion/1` |
| Activation | Yes: `activation` (`onStartup`, `onInterface`, `onOp`, `onEvent`, `onKeybinding`) | No `onCommand` |

## Gaps from the profiles lane

The codex profile (`examples/looks/codex/profile`, built from these docs only) found these:

| Surface | Expressible today? | Missing piece |
| --- | --- | --- |
| More than one feature look's customize app in one look | No: a look carries one `customize/` app (`local/customize`), and `implements` names each interface once | A whole profile cannot ship two `cmux.section/1` sections, so the codex sidebar's Chats and the codex threads' Activity cannot both ship. Allow a look to carry several apps (`customize/<name>/`), or let `implements` take a list per interface |
| A key for "next chat that needs you" | No: there is no public action for it (only `nextSidebarTab`, `focusNextPane` and the diff viewer's next file and hunk) | Add an action such as `agentPane.nextAttention` to the action catalog, so a profile can bind the reference app's key |
| Model and effort as separate chips | Partly: `cmux.composer.chip/1` can draw one, but only from the look's one app | A setting that splits effort out of the model menu into its own chip |
| Work location and branch chips under the composer, and moving a chat to a worktree | No | A composer chip row for location (local, worktree, cloud) and branch, and a chat op to move a chat between checkouts |
| `cmux customize apply NAME` when `CMUX_NEXT_CONFIG_FILE` is set | No: it exits 0 and prints "nothing to apply: what is live is already generation 1", while the toast says the config file is pinned | Exit non-zero and say why on the command line, so a script or capture run does not shoot stock cmux. `cmux setup install` works in that case |

## Order

1. `cmux.motion/1`: one typed and versioned motion contract in Rust (landed with this page).
2. `agentPane.display.streaming`: the streaming style setting.
3. `contributes.keybindings` with `onKeybinding` activation (landed).
4. Profile-level motion tokens: a `motion` block in a theme or look, bounded like `cmux.motion/1`. Rust side
   landed (`cmux-app-host/src/motion_profile.rs`, theme file `motion`, `theme.slots.resolve`); next: the app
   applies the answer to its chrome, and `.animation("presetName")` resolves a look preset.
5. Done (runtime 1.5.0): `cmux.pane/1` open arguments and results, so a pane can return a value (panel flows).
6. Done (runtime 1.6.0): view state that survives a hot reload (`ctx.keep`, `app.view.state`).
7. Timed transitions (`{kind, motion}`) (landed).

## The `motion` block (for agents)

A theme file (`themes/NAME.json`, and so a look, a theme pack or a profile that carries one) may set:

```json
{
  "motion": {
    "presets": { "drawer": { "duration": 0.32, "bounce": 0.1 } },
    "springs": { "move": { "duration": 0.18 }, "appear": { "duration": 0.16 } },
    "fades": { "fadeIn": 0.12, "hoverOut": 0.1 }
  }
}
```

- A spring is `{duration, bounce}`, as SwiftUI's `.spring(duration:bounce:)`: `duration` in seconds (the
  response), `bounce` 0 (no overshoot, the default) up to 0.7. Rust converts it: response = duration, damping
  fraction = 1 - bounce.
- Every number is clamped to `cmux.motion/1`: seconds in 0.05 to 10, damping fraction 0.3 to 1.
- `springs` and `fades` names are the design tokens' (`design-tokens.json` `motion.springs`, `motion.fades`).
  An unknown name, a malformed entry or a preset named like a `cmux.motion/1` token (`smooth`, `move`, ...) is
  left out with a diagnostic naming its path; the rest apply.
- No block, or an empty one, changes no timing.
- `cmux theme schema` prints the JSON Schema, `motion` included.

Copy-paste prompt:

> Give my look the feel of APP. In its theme file (`themes/NAME.json`), add a `motion` block: override only
> the design-token springs (`motion.springs`, each `{duration, bounce}`) and fades (`motion.fades`, seconds)
> whose timing differs from APP, and name any spring APP's panels share as a preset in `motion.presets`.
> Keep `bounce` 0 unless APP visibly overshoots. Check the file with `cmux theme schema`, and leave every
> other key alone.
