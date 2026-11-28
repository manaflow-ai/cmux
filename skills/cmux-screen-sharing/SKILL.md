---
name: cmux-screen-sharing
description: "Drive the screen of another of the person's devices (a Mac or a Linux machine) that cmux Screen Sharing shows: take a screenshot, click at a point given as fractions of the display, type text and press key combos with `cmux rd screenshot|click|type|key --device X --json`. Use when a task needs to see or operate a whole remote desktop through a Screen Sharing tab, when the person asks you to look at or use their other computer's screen, or when a `cmux rd` command refused and you need its next step."
---

# Drive a shared screen with `cmux rd`

cmux Screen Sharing shows another of the person's devices (a Mac or a Linux
machine) in a tab. `cmux rd` gives you four verbs on that screen, through the
same tab and the same input path the person's own mouse and keyboard use:

```bash
cmux rd screenshot --device studio --out /tmp/studio.png --json
cmux rd click      --device studio --x 0.5 --y 0.25 --json            # left click
cmux rd click      --device studio --x 0.9 --y 0.05 --button right --json
cmux rd click      --device studio --x 0.3 --y 0.6 --double --json
cmux rd type       --device studio "hello world" --json
cmux rd key        --device studio cmd+shift+4 --json
```

`--device` is the device's name or id. `cmux app mac-screens --json` lists the
open Screen Sharing tabs with `device`, `device_id`, `connected`, `has_frame` and
`frame` (the picture's pixel size). `cmux rd help` prints the usage.

For apps on this machine, or one window at a time on another machine, use
cmux Computer Use (`cmux-computer-use`) instead: it targets windows by id, works
in the background and does not need a Screen Sharing tab. `cmux rd` is for a
whole remote desktop the person is sharing.

## The loop

1. `cmux rd screenshot --device X --json`. The answer has `path`, `width` and
   `height`. Read the PNG.
2. Find the target in the picture and turn its pixel into fractions:
   `x = pixel_x / width`, `y = pixel_y / height`. 0 is the left or top edge,
   1 the right or bottom edge. Fractions keep working whatever size the
   screenshot is shown or scaled to.
3. Act: `click`, `type`, `key`.
4. Screenshot again to check before the next step. A remote screen changes on
   its own (a dialog, a slow app): never chain several clicks blind.

A click answers `pixel` (where it landed in the stream) and `frame` (the size it
was mapped against). Typed text goes as committed text, so any keyboard layout
and any language work; use `key` for shortcuts and keys like `return`,
`escape`, `tab`, `up`, `f5`, `ctrl+alt+delete`. Modifiers are `cmd` (the
Windows or Super key on Linux), `ctrl`, `alt` (Option) and `shift`.

## Errors tell you the next command

With `--json`, every refusal is one object on stderr:

```json
{"error": "view_only",
 "reason": "the tab views \"studio\" without control: rd click needs Full Control, which its owner allows",
 "next": "cmux tab new-mac-screen --device studio --scope full",
 "code": "rd.view_only", "retryable": false, ...}
```

Run `next`. When `retryable` is true, `next` is the same command again: wait a
few seconds and run it. The usual ones:

| `error` | Meaning | `next` |
| --- | --- | --- |
| `no_screen_tab`, `not_connected` | No connected tab shows that device | `cmux tab new-mac-screen --device X --scope view` (`--scope full` for input) |
| `connecting` | The tab is still connecting | this command again |
| `waiting_for_approval` | The device's owner has not allowed this Mac yet | this command again |
| `view_only` | The tab views without control | `cmux tab new-mac-screen --device X --scope full` |
| `control_not_allowed` | The device lets this Mac view only | `cmux rd screenshot --device X` |
| `signed_out` | This Mac is not signed in to cmux | `cmux login` |
| `device_offline`, `not_shared`, `unknown_device`, `not_allowed` | The device can't be reached or does not share | `cmux device list` |
| `frame_changed` | The display changed size since your screenshot | `cmux rd screenshot --device X` |
| `session_ended`, `declined` | The session is over | the open command again |
| `app_unreachable` | The cmux app does not answer | `open -a cmux` |
| `app_outdated` | The running app predates these commands | `cmux settings check-for-updates` |
| `usage` | A bad argument | `cmux rd help` |

## What you may not do

- Control is the device owner's grant. `cmux rd` never asks for it on its own
  and never answers an approval. When `next` asks for Full Control, the owner
  allows it on their device; tell the person what you are waiting for.
- Never work around a refusal with another tool (osascript, xdotool, a VNC
  client) or by changing Screen Sharing settings.
- Never type a password or a secret into a remote screen unless the person
  gave it to you for that purpose.
