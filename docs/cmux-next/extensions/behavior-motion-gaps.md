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
| Named motion presets shared by an app's nodes | Partly: a JS constant passed to `.animation()` | No manifest- or theme-level preset table, so a profile cannot retime its extensions in one place |
| Chrome motion (tab reflow, sidebar, palette, hover card) | No: only `ui.animationSpeed`, `ui.animation`, `ui.paneAnimations` | The design-token springs and fades (`design-tokens.json` `motion`) are compiled in. A profile cannot set its own timings, so codex-app and t3-code cannot match their apps' feel |
| Streaming style of agent text (reveal, cursor, chunk fade) | No: only `agentPane.display.thinking.glyph` and `transcriptLook` | No `agentPane.display.streaming` setting (reveal per token, per line or instant, and its fade). Every web-coding-app profile needs one |
| Scroll and gesture motion inside a pane scene | No | No scroll-linked props: an extension cannot pin a header or fade content against its scroll position |

## Behavior

| Surface | Expressible today? | Missing piece |
| --- | --- | --- |
| Palette commands | Yes: `cmux.palette.scope/1` and the action catalog (`action.run`) | None found |
| Slash commands in the composer | Yes: `cmux.composer.command/1`, from the manifest alone | None found |
| Keybindings an extension declares | Yes: `contributes.keybindings` in keybindings.json form (`{key, command, when?, args?}`, the same parser), an own op or a cmux action, in the app binding layer below the person's keybindings.json; a pair bound twice warns (`keybindings.shortcutConflict`) | Bare keys outside a bare-key `when` stay the person's |
| Menus and toolbar items | Yes: `contributes.menus`, `contributes.toolbarItems` | None found |
| Panes and overlays | Yes: `cmux.pane/1` (`presentation.overlay` too), `cmux.section/1`, `cmux.newtab/1` | `cmux.pane/1` has no `onOpen` or `onClose` events or open arguments, so a panel flow (a picker that opens a detail pane and returns a result) has to be put together from storage and palette ops |
| Pane state that survives a reload | Partly: `app.storage.*`, and `cmux ext dev` hot-reloads the script | Scene state (scroll position, focused field, expanded rows) is lost on a hot reload. There is no `state` export the host keeps and hands back |
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
4. Profile-level motion tokens: a `motion` block in a theme or look, bounded like `cmux.motion/1`.
5. `cmux.pane/1` open arguments and results, so a pane can return a value (panel flows).
6. Scene state that survives a hot reload.
7. Timed transitions (`{kind, motion}`) (landed).
