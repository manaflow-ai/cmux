---
name: cmux-ui-preview
description: "Show UI work in the chat by default: start the surface's live mode, open the preview in a cmux browser tab you created, and cmux puts a before and after picture of that page on the turn's edited-files card on its own; `cmux browser <tab> screenshot` when you must see it yourself; end with how to try it. Use before your first edit to any UI (webviews, Settings, chat pane, a site, the Rust daemon's UI, Swift views)."
---

# Live UI preview in the chat

When you change UI, the person sees it in the chat without asking: the page you preview, live,
and a before and after picture of it on each turn's edited-files card. You do not need permission
to do any of this; it is the default for UI work. You only do these four things.

## 1. Before your first UI edit: start live mode and open the preview

Start the live mode for the surface (details in the `cmux-live` skill):

| Surface | Start |
|---|---|
| Web (`webviews/`, any Vite or React app) | `cmux live start --worktree <checkout>` (saved edits show at once) |
| Rust (cmux-tui, acpmux) | `cmux live start --rust --build-host HOST`; a merged commit: `scripts/cmux-next/hot-apply.py apply SHA` |
| Swift edits inside function bodies | `cmux live start --swift` (live code) |
| A copy of the person's NIGHTLY with your web or daemon change | `cmux app try .` |

Then open the page in a cmux browser tab from your chat (the `cmux-browser` skill):

```bash
cmux --json tab create browser --url http://127.0.0.1:<port>/<path>
```

A tab you open or drive this way is agent-driven. Only agent-driven tabs are ever captured; a
tab only the person used is never touched.

## 2. Just work

Edit, save, build as usual; the live mode swaps each save into the open page. When a turn starts,
acpmux captures the selected agent-driven http(s) tab of the chat's workspace, and when the turn
settles it captures that tab again (turn shots, `cmux-tui/crates/acpmux/src/hub/turn_shots.rs`).
If the two differ, the pair shows on the turn's edited-files card. Keep the preview tab selected in
the chat's workspace so the pair is of the page you changed. Do not paste screenshots into your
replies to show progress; the card already shows it.

## 3. Look or drive only when you need to

- Start with the `look` MCP tool when you only need a cheap check of the latest frame. It returns
  one JPEG (at most 512 px on its long edge) from the selected agent-driven tab when one is showing,
  plus one line naming the tab, its URL when available, its dimensions and dHash movement. If no page
  is showing, the safe fallback is a whole-window frame labelled `window`; open an agent-driven page
  before using browser selectors or interaction. It does not click or type.
- Use `cmux browser "$TAB" screenshot --out shot.png` (`--selector "#el"`, `--full-page`) when you
  need to judge layout or a regression in detail. Read the file to see it.
- Use `cmux browser "$TAB" snapshot --interactive`, then `click`, `fill` and the rest on the same
  tab, or cmux Computer Use (`cu_*`), when the flow needs interaction. For an agent-driven page, the
  `look` result and these tools use the same tab; a `window` result has no page to drive, so open one
  first (the `cmux-browser` and `cmux-computer-use` skills).

## 4. At turn end: say how to try it

End with `wrap_up` (its actions are plain strings). Put the exact command in the recap:
`cmux app try <PR>` (a copy of the person's NIGHTLY with the change swapped in) or, for a web-only
change, `cmux customize use pr:N` (undo: `cmux customize library off pr-N`; the `cmux-hot-loop`
skill lists the branch, commit and working-copy forms). When you want their answer, ask:

```json
{
  "recap": "The sidebar rows are 4 px tighter; the turn's card shows before and after. Try it: cmux app try 123.",
  "ask": "Keep the tighter sidebar?",
  "actions": ["Keep it", "Not now"]
}
```

When you are done previewing, `cmux live stop` (`--rust`, `--swift` for those), unless the person
wants to keep looking.
