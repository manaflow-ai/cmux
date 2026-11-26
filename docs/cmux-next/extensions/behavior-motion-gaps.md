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
| Enter and exit transitions of a node | Yes: `.transition(opacity slide scale move pop)` | A transition takes no timing: it always uses the renderer's own spring. A `{kind, motion}` form would let a profile match another app's panel timing |
| Looping effects (pulse, breathe, spin, ...) | Yes: `.loop({effect, period, amount})` | The native renderer clamps `amount` to [0, 10], so a counterclockwise `spin` (negative amount, as ABI.md says) turns clockwise on macOS. Fix it in `Motion+AppScene.swift` |
| Particles and choreographed glyphs | Yes: `Particles({preset})`, `cmux.particles/1` (validated in Rust) | None found |
| Named motion presets shared by an app's nodes | Partly: a JS constant passed to `.animation()` | No manifest- or theme-level preset table, so a profile cannot retime its extensions in one place |
| Chrome motion (tab reflow, sidebar, palette, hover card) | No: only `ui.animationSpeed`, `ui.animation`, `ui.paneAnimations` | The design-token springs and fades (`design-tokens.json` `motion`) are compiled in. A profile cannot set its own timings, so codex-app and t3-code cannot match their apps' feel |
| Streaming style of agent text (reveal, cursor, chunk fade) | No: only `agentPane.display.thinking.glyph` and `transcriptLook` | No `agentPane.display.streaming` setting (reveal per token, per line or instant, and its fade). Every web-coding-app profile needs one |
| Scroll and gesture motion inside a pane scene | No | No scroll-linked props: an extension cannot pin a header or fade content against its scroll position |

## Behavior

| Surface | Expressible today? | Missing piece |
| --- | --- | --- |
| Palette commands | Yes: `cmux.palette.scope/1` and the action catalog (`action.run`) | None found |
| Slash commands in the composer | Yes: `cmux.composer.command/1`, from the manifest alone | None found |
| Keybindings an extension declares | No: a person sets `keybindings.*` in their own config; a manifest has no `contributes.keybindings` | Add `contributes.keybindings` (`{key, action, when?}`), checked against `catalog.shortcutConflict`. Without it, the claude-code-app profile cannot bind its own Esc and Cmd-K flows |
| Menus and toolbar items | Yes: `contributes.menus`, `contributes.toolbarItems` | None found |
| Panes and overlays | Yes: `cmux.pane/1` (`presentation.overlay` too), `cmux.section/1`, `cmux.newtab/1` | `cmux.pane/1` has no `onOpen` or `onClose` events or open arguments, so a panel flow (a picker that opens a detail pane and returns a result) has to be put together from storage and palette ops |
| Pane state that survives a reload | Partly: `app.storage.*`, and `cmux ext dev` hot-reloads the script | Scene state (scroll position, focused field, expanded rows) is lost on a hot reload. There is no `state` export the host keeps and hands back |
| Composer layout (toolbar, chips, model and reasoning picker) | Yes: `cmux.composer.toolbar/1`, `cmux.composer.chip/1`, `cmux.composer.model.picker/1` | None found |
| Chat message actions and widgets | Yes: `cmux.chat.action/1`, `cmux.chat.widget/1` | None found |
| Hover cards and sidebar row decorations | Yes: `cmux.hovercard/1`, `cmux.sidebar.rows/1` | `cmux.sidebar.rows/1.json` was not valid JSON (unescaped quotes in `docs`), so its options schema did not load. Fixed in the same PR as `cmux.motion/1` |
| Activation | Yes: `activation` (`onStartup`, `onInterface`, `onOp`, `onEvent`) | No `onKeybinding` or `onCommand`, which goes with `contributes.keybindings` |

## Gaps from the profiles lane

None are recorded here yet. On 2026-11-25 goal-customize-app-profiles-a had been closed for 22 hours and had
not written its gaps down. When the lane that adopts it finds one, it adds a row above.

## Order

1. `cmux.motion/1`: one typed and versioned motion contract in Rust (landed with this page).
2. `agentPane.display.streaming`: the streaming style setting.
3. `contributes.keybindings` with `onKeybinding` activation.
4. Profile-level motion tokens: a `motion` block in a theme or look, bounded like `cmux.motion/1`.
5. `cmux.pane/1` open arguments and results, so a pane can return a value (panel flows).
6. Scene state that survives a hot reload.
7. Timed transitions (`{kind, motion}`).
