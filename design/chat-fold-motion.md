# Chat folds: exit before move

The agent chat pane (cmux NEXT, `webviews/src/agent-session/acpmux`) folds more than Claude Code
does. A finished turn's work folds under "Worked for", like ChatGPT's "Thought for". Claude has no
protocol for that, so these rules are ours, and every fold follows them.

Leo, 2026-11-21: "i rather dislike the folding right now bc the text is still visible as it gets
folded/"collapsed" / we are folding more than what claude code does, aka we're doing it like chatgpt,
but we're donig it for claude. but they dont have a protocol for that. so we're figuring shit out on
our own. in these cases, we must be meticulous. there are guidelines and best practices we're not
following. anyways, that text hiding as it travels so it doesnt show weird overlays is the big one. we
prev dealt with this when collapsing groups. we must hide text faster and sooner"

## The rules

1. **Exit before move.** Text a fold takes away is gone before anything moves. That includes a body
   shrinking and rows sliding over where the text was. The move starts when the exit ends.
2. **A short opacity lead.** The exit is a fade from the text's current ink to 0. It runs over
   `--cv-exit-lead` (`EXIT_LEAD_MS`, half the quick step: 40 ms) on the house ease-out
   (`--cmux-ease-out`), which drops the ink fastest at the start. It is never more than a third of
   the fold, and text that is already faint (a close that reverses an open) gets a proportionally
   shorter lead.
3. **No overlap during travel.** No text that is leaving is drawn while rows travel over its place.
   The clips from #43896 (`coverClip`, the turn end's crop) still hold each copy outside the rows
   that come over it. Since the copy is invisible by the time anything moves, those clips are now a
   second guard rather than the only one.
4. **Opening has no lead.** Nothing leaves when a fold opens, so the move starts at once. Leo's "No
   fade in. Just boom" (2026-10-24) still holds for bodies that open at full opacity.
5. **One clock per role.** The exit has one clock and the move has another. Every row, copy and clip
   in a fold runs on the move clock. A row that mounts mid-fold joins part way through, and before the
   move starts it holds its starting place (`fill: backwards`). It never jumps to where it lands.
6. **Motion off means at once.** Reduce Motion, `data-agent-motion="off"`, `data-cmux-motion` set to
   off or reduced, or a 0 ms token: the fold applies at once, with no lead.

## Where each fold applies it

| Fold | Code | Exit | Move |
|---|---|---|---|
| A body closing: tool group, tool, command, MCP, thought, notice group, subagent lines | `conversation/fold.ts` `useFold`, `exitLead.ts` `exitThenClose` | One animation: ink to 0 over the lead while the height holds | Height to 0 on the settle, after the lead |
| "Worked for" or a subagent group closing (reader toggle) | `conversation/turnFold.ts` | Each hidden row's copy fades out over the lead | Rows below slide up after the lead |
| A turn's end (its work folds into "Worked for") | `conversation/turnEndFold.ts` | Each removed row's copy fades out over the lead (staggered within it in the `stagger` look) | Kept rows, copies and clips on the settle, after the lead. Rows the swap added fade in on the move clock |
| The read "New since you looked" line | `conversation/unread.css` | Rule, tag and words fade over `--cv-exit-lead` | Height shrinks on the calm step, delayed by the lead |

## Best practices followed

- **Material Design motion, "Fade through" and "Container transform"** (material.io, Motion,
  Transition patterns): outgoing content fades out completely in roughly the first third of the
  transition, before incoming content or the container's change takes over, so the two never show at
  once. Our lead is shorter than Material's 90 ms because Leo wants the text gone "faster and sooner".
- **Material Design motion, "Speed: exits are faster than entrances"**: leaving elements use a
  shorter duration than arriving ones. Our exit is 40 ms, and opening has no exit at all.
- **Apple Human Interface Guidelines, Motion**: motion should be brief and purposeful, and should
  never show content in a confusing or overlapping state. Under Reduce Motion it is removed rather
  than shortened, which is rule 6.
- **Apple HIG, "Make motion optional"**: no information is carried only by the fold's motion. The
  folded line names what it holds ("Worked for 2m 10s").

## Tests

- `webviews/test/fold-exit-before-move.test.ts` checks that every fold path hides its leaving text
  before its first moving frame.
- `design/chat-animation-ordering-map.md` is the map of event orders around a tool call's end.
  Each order there names its test.
