---
name: cmux-cua
description: "cmux Computer Use. Read this skill before the first step of any request, in a cmux chat, to do something in an app on the person's computer (Calculator, Notes, Finder, a text editor, Settings, any desktop app) or on one of their other machines, or to look at their screen. In a cmux chat this is the computer use tool: the tools of the `cmux-computer-use` MCP server (or the `cu_*` tools folded into the `cmux` server), attached by cmux to every agent session it starts. Use it, not another app's computer-use skill or tools, and never osascript, AppleScript, System Events keystrokes, xdotool or SendKeys, which skip cmux's deny list and the person's settings. Covers modes, denied apps, background input and other machines."
---

# cmux Computer Use

cmux Computer Use is built into cmux on macOS, Linux and Windows. cmux attaches
it to every agent session it starts (Claude Code, Codex and the other ACP
harnesses) as the MCP server `cmux-computer-use`; in code mode its tools are
also folded into the `cmux` server with the prefix `cu_` (`cu_click`). There is
nothing to install and no other computer-use driver is needed. Architecture:
[docs/computer-use/README.md](../../docs/computer-use/README.md).

The tools list is always there, even while the machine's Computer Use worker
starts or restarts: a call made then waits for it instead of failing.

## When to use it

- Any task that needs an app's UI or a look at the screen ("open Calculator and
  compute 128 x 46", "what is on my screen", "rename this file in Finder"). The
  request for the task is the request: the person does not have to name
  computer use.
- Not when a web page is the target (use `cmux-browser`), or when the task needs
  no app UI (a shell command, a file edit, an answer you already know).
- Never drive apps with `osascript`, AppleScript, JXA, System Events,
  `cliclick`, `xdotool`, `ydotool`, PowerShell SendKeys or raw event posts. If a
  Computer Use call is refused, say why and stop; do not switch to another way
  of driving the app.

## The loop

1. `list_windows` (optionally with `app_id`), or `list_apps`. `launch_app` starts
   an app without bringing it to the front where the platform allows.
2. Look at one window: `get_ui_tree` (element ids, roles, names, values,
   actions) or `screenshot` with its `window_id`. A window screenshot works when
   the window is covered. `screenshot` returns `unchanged: true` and no image
   when nothing changed since your last screenshot of it; pass `force` only when
   you need the image again.
3. Act on element ids (best: they work in the background and survive layout
   changes) with `click`, `set_value`, `perform_action`, `type_text`, or on
   pixels of your latest screenshot of that window (`x`, `y`). With no
   `window_id`, coordinates are pixels of your latest display screenshot.
4. Check the result with another `get_ui_tree` or `screenshot`, then go on.

Coordinates are always screenshot pixels; cmux maps them to the desktop, so do
not scale them yourself.

## Background input and the person

- Input is background by default: no app is activated, the person's pointer
  never moves and their keyboard focus stays where it is. A blue cmux cursor
  (#0A84FF) shows them where you act.
- `delivery: "foreground"` raises the window and uses system-wide input. Use it
  only when background delivery failed for that step, and only when the person
  allowed it (Settings → Computer Use → Allow foreground input). Otherwise it is
  refused with `foreground_not_allowed`.
- When the person takes over (moves the pointer or types), Computer Use pauses
  while they do (Settings → Computer Use → Pause when I take over). A paused call
  waits; do not fight the person for input.
- When a route cannot prove where an input would land, the call is refused
  rather than guessed. Pick another target (an element id, another window)
  instead of retrying the same call.

## Modes, denied apps and refusals

The person picks a mode in Settings → Computer Use (default Full access):

| Mode | What works |
| --- | --- |
| Off | Nothing (`computer_use_off`). |
| Look only | `list_*`, `screenshot`, `get_ui_tree`; every action is refused (`look_only`). |
| Ask every time | cmux asks the person before the first action in an app; the call waits for their answer. |
| Approved apps | Apps the person approved run at once; others ask once. |
| Full access | Every app that is not denied. |

- Denied apps (`app_denied`) are refused in every mode. The default list holds
  password managers and keychains, System Settings, terminals and cmux itself;
  the person can edit it. Denied windows are listed with `denied: true` and are
  painted out of display screenshots.
- Protected targets (`app_protected`) are never usable and not on the list: the
  OS sign-in and authentication prompts (SecurityAgent, loginwindow, UAC
  consent, polkit agents) and cmux Remote.
- `app_never_allowed`: the person chose Never for that app.
- After any refusal call `status`, tell the person in one line which setting
  would allow it, and go on with the rest of the task. Never retry a refused
  call, and never try to change a `computerUse.*` setting yourself: agents are
  refused every one of them.
- cmux, not the agent, asks the person. Never ask for permission in text; call
  the tool and cmux shows its own prompt when the mode needs one.

## OS permissions

macOS needs Accessibility and Screen Recording for cmux Remote (one TCC identity
for every Computer Use session; cmux's onboarding grants them). When `status`
shows a missing permission, call `request_permission` once and tell the person
what to allow; do not loop on it.

## Other machines

`list_machines` lists the person's other machines running cmux (signed in as
them, Computer Use on). Pass a machine's name as `machine` to any tool. Their
own machines need no prompt when the target is in Full access; a target can
refuse with `remote_not_allowed`. Calls from another account's machine are
never accepted (`foreign_account`). Cloud VMs are unrestricted.

## Troubleshooting

- `status` first: platform, display server, permissions, mode and denied apps.
- A call made while the worker restarts waits and runs once; a retried call with
  the same `call_id` never runs twice, so a reconnect cannot double-click.
- Linux: X11 and headless Xvfb sessions are supported; on Wayland, `status`
  reports what the compositor allows.
