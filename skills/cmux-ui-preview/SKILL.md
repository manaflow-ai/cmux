---
name: cmux-ui-preview
description: "Show UI work in the chat as it forms, at no token cost: start the surface's live mode, open the preview in a browser tab, and cmux captures frames into the chat on its own; `look` when you need to see it, then a Try it on button at turn end. Use before your first edit to any UI (webviews, Settings, chat pane, a site, the Rust daemon's UI, Swift views, iOS)."
---

# Live UI preview in the chat

When you change UI, the person sees it in the chat as you build it: a strip of frames and a live
preview window, then a Try it on button at turn end. cmux does the capturing. You only do these
four things.

## 1. Before your first UI edit: start live mode and open the preview

Start the live mode for the surface (details in the `cmux-live` skill):

| Surface | Start |
|---|---|
| Web (`webviews/`, any Vite or React app) | `cmux live start --worktree <checkout>` (React Fast Refresh) |
| Rust (cmux-tui, acpmux) | `cmux live start --rust --build-host HOST`; a merged commit: `scripts/cmux-next/hot-apply.py apply SHA` |
| Swift, Debug build | `cmux live start --swift` (live code) |
| Release NIGHTLY | `cmux app try .` |

Then open the page in a cmux browser tab from your chat:

```bash
cmux --json tab create browser --url http://127.0.0.1:<port>/<path>
```

That tab is now your agent-driven tab, so cmux captures it when you edit a UI file, when a build
finishes and at turn end. Open one tab per surface you preview; each gets its own strip.

## 2. Just work

Edit, save, build as usual. Frames show up in the chat on their own. Do not take screenshots by
hand, and do not paste images into your replies to show progress.

## 3. Look or drive only when you need to

- `look` (acpmux MCP tool): the latest frame at 512 px, about 500 tokens, plus the tab URL and how
  far it moved since the turn's first frame. Call it when you must judge the result yourself
  (layout, a regression), not after every edit. The person sees that frame too.
- To click through a flow, use the cu_* computer-use tools or `cmux browser <tab> click|fill|...`
  on the same tab (the `cmux-browser` skill).

## 4. At turn end: offer Try it on

Call `wrap_up` with a Try it on action that points at your work:

```json
{
  "recap": "...",
  "ask": "Try the new sidebar on your app?",
  "actions": [
    {"label": "Try it on", "run": {"customize": "try", "target": "pr:123", "minutes": 30}},
    "Not now"
  ]
}
```

`target` is `pr:N`, `branch:B`, `sha:S`, `dir:PATH` or a customization `NAME`. The card then offers
Keep (`{"customize":"keep"}`) and Revert (`{"customize":"revert"}`); an untouched try reverts itself
when its minutes end. A chat that only takes string actions still shows the label.
