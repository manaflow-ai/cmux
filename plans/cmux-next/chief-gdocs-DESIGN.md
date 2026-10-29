# Google Docs tools for Chiefs and agents

Status: v1 landed 2026-10-25 (a670). Branch `feat-cmux-next`. Pack: `Native/OptChat/optchat-chief/toolpacks/gdocs/`
(pack.toml, SKILL.md, the `gdocs` script). Tests: `tests/toolpack_gdocs.rs`.

User (Lawrence, 2026-10-25): "we need to improve our google doc tools somehow". Before: a668 read a doc
through `/mobilebasic` by hand; a669 tried real keystrokes (ignored, stray text), then wrote a one-off
JS select-all + synthetic HTML paste, with no check but a manual HTML export.

## 1. What the Docs editor allows (checked live on a scratch doc, cmux NIGHTLY WebKit tab)

| Operation | Works | How |
|---|---|---|
| Real key presses (`cmux browser TAB press`) | no | a background tab gets no caret move: `Meta+ArrowUp` then a paste landed at the end |
| Synthetic `KeyboardEvent` keydown/keyup on `iframe.docs-texteventtarget-iframe [contenteditable]` | yes | Cmd+A, Cmd+Up/Down, ArrowRight, Cmd+F, Cmd+Option+M (comment), Cmd+Option+Shift+X/Z (Suggesting/Editing) |
| `keypress` events | harmful | Docs types the keyCode as a character (ArrowRight's 39 typed `’`): never sent |
| Synthetic `ClipboardEvent('paste')` with `text/html` | yes | headings, bold, links, nested lists, tables; replaces the selection; one undo step |
| Same-origin `fetch('/document/d/ID/export?format=…')` | no | 302 to another origin: `Failed to fetch` |
| Same-origin `fetch('/document/d/ID/mobilebasic')` | yes | the saved doc as HTML: lists with `lst-kix_…-LEVEL` classes, comment notes `#cmnt…` |
| `DOMParser` on that HTML | needs a Trusted Types policy | the page enforces `require-trusted-types-for` (the tool parses in Python instead) |
| `cmux browser TAB screenshot` | no, for agents | "Only a person in cmux can run this action": verify reads the saved doc, not pixels |
| Find box count ("1 of 3") | yes, async | updates a moment after the query; the tool resets it with a no-match query first and waits on the count |
| Suggestions | yes | a paste in Suggesting mode; its card (`.docos-anchoredreplyview-body`, "Add: “…”") is the verify signal |

## 2. The tool (`gdocs`, on every turn's PATH)

```
gdocs read DOC [--format md|json|html]
gdocs replace-outline DOC --md FILE|- [--suggest]
gdocs insert DOC --text MD [--at start|end | --after TEXT [--inline]] [--suggest]
gdocs comment DOC --on TEXT --text COMMENT
gdocs verify DOC --md FILE [--mode exact|contains]    (or --html FILE offline)
gdocs open DOC
```

Two routes, chosen per call:

1. **API** (`GDOCS_TOKEN` set, from `chief pack paste gdocs -`): Drive v3 export as HTML (read),
   `PATCH /upload/drive/v3/files/ID?uploadType=media` with HTML (replace, Drive converts it into a
   Google Doc body), `comments.create` (comment, unanchored in the UI). No browser. `insert` stays
   on the browser route (Docs `batchUpdate` index math is a v2 item).
2. **Browser** (default, no secret): the person's own Google session in the agent's own cmux tab,
   through `cmux browser TAB eval|wait|navigate`. A small page library (`window.__cmuxGdocs`,
   versioned by its own hash so a tab with an older copy reloads it) does the synthetic events.

Every write is verified: the doc is read back (mobilebasic or export) and its outline (kind,
list level, normalized text per block) is compared with the Markdown's; a bounded retry covers
Docs' save delay. Exit 0 verified, 1 written but different (first difference in the JSON), 2 not
done (`signed_out`, `read_only`, `not_found`, `no_editor`, ...). A failed suggestion still puts the
doc back in Editing mode.

### Why the API sign-in is a pasted token, not a device code

Google's OAuth device flow (the a607 GitHub pattern) only allows `drive.file` and `drive.appdata`
among Drive scopes, which cannot open an existing doc the app did not create. A full Drive scope
needs a browser OAuth client with a redirect, which cmux has no registered Google app for yet.
v1: `gcloud auth login --enable-gdrive-access` then `gcloud auth print-access-token | chief pack
paste gdocs -` (valid about an hour). v2: a cmux Google OAuth app (loopback redirect), then
`methods = ["device"]`-like `chief pack login gdocs` through the existing core.

## 3. From browser-use (studied 2026-10-25)

Licenses: browser-use, browser-harness, web-ui, template-library, macOS-use: MIT. workflow-use: AGPL-3.0
(nothing taken). No browser-use repo handles the Docs editor (no `docs-texteventtarget-iframe`,
no `kix`); all their typing assumes CDP.

Taken (ideas, no code copied):

- `browser-harness/agent-workspace/domain-skills/google-sheets/writing-cells.md`: read back through
  the export after every write and treat an account-chooser 200 as signed out (here: `signed_out`
  when mobilebasic is not a doc page).
- browser-use 0.5.4 `browser_use/controller/service.py` L965-1063 (removed later): a synthetic
  `ClipboardEvent('paste')` is accepted by Google editors. Their payload went into a JS template
  literal unescaped; here every value is `json.dumps`-quoted.
- `browser_use/agent/judge.py` L101/L127: a task about a Google Doc fails if the agent only returns
  text. The SKILL says to write to the doc and verify, never hand back a copy.

Not taken: the DOM serializer and paint-order filter (Docs content is not in the DOM),
workflow-use replay (AGPL, no canvas support), CDP `Input.insertText` / `iframe_target`
(cmux's browser verbs are not CDP; the synthetic events on the event-target iframe do the same job).

## 4. Measurements (scratch doc "cmux gdocs scratch (a670, safe to delete)", never Lawrence's docs)

Reformat a flat 30-bullet doc (38 paragraphs) into the outline in `tests/fixtures/gdocs/roadmap.md`
(title, intro with bold and a link, 6 sections, 30 bullets with 12 nested, a 3-row table: 42 blocks):

| | Before (a669, 2026-10-25) | After (`gdocs replace-outline`) |
|---|---|---|
| Success | keystrokes failed; a hand-written paste worked on a later try | 5 of 5, each verified exact (42/42 blocks) |
| Time | not measured (several attempts by hand) | write 0.10-0.18 s, total with verify 1.0-2.4 s |
| Verify | a manual HTML export, headings and bullets counted | automatic outline compare, exit 1 on any difference |
| Agent effort | one-off JS, written per task | one command |

Insert after text, comment and suggestion also verified live on the same doc.

## 5. Later

- API `insert`/`comment` anchored through Docs `batchUpdate` (needs index math from `documents.get`).
- A cmux Google OAuth app so `chief pack login gdocs` works with no gcloud.
- Sheets: move a620's `safe_sheets.js` (cmuxterm-hq `tools/aside-wrapper/`) into a `gsheets` pack
  with the same shape (export read-back, account lock).
- CEF panes: not checked yet (the event-target iframe should be the same).
