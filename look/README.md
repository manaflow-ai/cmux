# studio

A look for cmux NEXT that looks and works like the reference app: a true black desktop agent GUI with
a sidebar of chats on three lines, a narrow 46rem chat column, your prompt in a dark pill, a rounded
composer with a deep soft shadow and an indigo primary.

## Install

```sh
cmux customize use manaflow-ai/cmux@lane/look-studio   # the web layer: chat, composer, New Tab
cmux customize use look/profile.json                    # settings, theme file, chat stylesheet
```

## What is in it

- `profile.json`: the whole profile (cmuxProfile 1), settings with `themes/studio.json` and
  `agent-pane/theme.css` inlined. Built from `src/` by `node look/build-profile.mjs`.
- `src/settings.json`, `src/theme.json`, `src/agent-pane.css`: its sources.
- `webviews/src/look/studio.css`: the web layer's stylesheet, loaded last by the agent pane
  (`webviews/src/agent-session/acpmux/mount.tsx`). Colors, radii, fonts and the chat column only;
  row heights stay as the transcript model measures them.
- `webviews/src/look/studio.ts`: the reference app's words (the composer's placeholder, the
  breadcrumb's slash).
- Web code changed for the look: the composer placeholder (`Composer.tsx`), the attach button's
  paperclip (`ComposerPlusMenu.tsx`), the New Tab field's placeholder (`NewTabPage.tsx`) and the
  "project / chat title" breadcrumb (`header/ThreadTitle.tsx`, `App.tsx`).
- `PARTS.md`: the reference, part by part, matched, close or gap.
- `captures/`: the reference beside ours.

## Tokens (from the reference app's open-source stylesheet, dark)

| Token | Value |
|---|---|
| background | `#000` |
| foreground | `#f1f3f7` |
| muted foreground | `#a3a3a3` |
| border | `rgb(255 255 255 / 8%)` |
| input | white at 18% |
| primary | `oklch(0.571 0.21 264)` |
| radius | `0.5rem` |
| chat column | `46rem` |
| top bar | `52px` |
| composer shadow | `0 14px 32px -18px rgb(0 0 0 / 75%)` |
| UI font | `-apple-system`, Inter |
| mono | `ui-monospace`, SF Mono |
