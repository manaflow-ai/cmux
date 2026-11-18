# The Codex app look (light)

cmux NEXT made to look and work like the Codex desktop app: a gray translucent sidebar of threads
under their project folders, a white page, your prompt in a gray pill, the reply as plain text, and
a large white composer with the model and effort inside the box.

## Install

One command, in a running cmux NEXT:

```sh
cmux customize use manaflow-ai/cmux@lane/look-codex
```

That applies `look/profile.json` (settings, the `codex-app` theme file, the chat stylesheet and the
"Threads" sidebar section) and swaps in this branch's `webviews/` build.

## What is in it

- `look/profile.json`: the whole cmuxProfile, files inlined:
  - `themes/codex-app.json`: Builtin Light, a `#d9d9d9` sidebar at 92% (translucent), a white
    page, no borders, flat chrome, neutral accent.
  - `agent-pane/theme.css`: the chat's colors and radii, for a cmux without this branch's web build.
  - `customize/cmux-app.json`, `customize/main.js`: the sidebar section (New thread, Automations,
    Skills, a "Threads" header, then threads by project with their age). The same two files are in
    `look/customize/`.
  - Settings: chats grouped by folder with times, comfortable density, no spaces, the lone chat tab
    hidden, the system font at 15 px, a 1000 px chat column, messages presentation.
- `webviews/` (the web layer):
  - `src/agent-session/acpmux/look/codexLook.css`: prompt pill, code chips, blue links, the white
    24 px composer with its shadow, the dark round Send, the model on the left of the in-box row,
    the white scroll-to-bottom disc, and New Tab's heading and strip.
  - `composerLook.ts` pins Codex's composer (the in-box row) in every chat and on New Tab and hides
    the look dots (`PINNED_COMPOSER_LOOK`).
  - The placeholders read "Ask for follow-up changes" (chat) and "Ask anything, @ to add files, /
    for commands" (New Tab); New Tab says "Let's build" over the composer.

Check the profile in a throwaway HOME:

```sh
T=$(mktemp -d); export HOME=$T XDG_CONFIG_HOME=$T/c XDG_STATE_HOME=$T/s
cmux customize use look/profile.json && cmux customize check && cmux theme check
```

`look/PARTS.md` lists every part of the reference and how close it is; `look/captures/` has the
side-by-side captures.

Captures in `look/captures/` are web-layer renders (the agent pane in headless Chromium under
Builtin Light, no sidebar) beside the reference; a real-app capture from the fleet replaces them
when it lands.
