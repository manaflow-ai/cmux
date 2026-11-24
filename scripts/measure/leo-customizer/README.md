# Leo's Customizer

A cmux NEXT app: a **Customize** section in the bottom-left sidebar with grouped, one-click
customizations. It lives here, outside the cmux monorepo, and only on Leo's NIGHTLY.

| Group | Rows (a click does this) |
| --- | --- |
| Look | Theme file (opens Settings at it; the "Theme file…" menu asks a /customize agent to switch to harbor, moss, meadow, lily-pond, phosphor, charcoal, claude-desktop or classic-desktop), Accent, Change background…, Interface size − Reset +, Animations on/off |
| Sidebar | Density Compact / Comfortable / Expanded (checkmark on the current one), Compact workspace list, Controls only on hover, Spaces, Sidebar text size, Section look, Customize sidebar… |
| Chat | Chat display… (the chat's display panel), Chat text size, Code size, Chat font |
| Quick toggles | On/Off badge per setting: Vertical tabs (flips it), Full-width chat, Pinned plan, Finish sound, Prompt coach, Sidebar timestamps, Detailed status icons, Minimal sidebar, Hover cards, Composer v2 |
| Actions | Open Settings, Customize with an agent… (a /customize chat), Customize one element…, Roll back a customization… (`customize.reset` per element), Reload custom views, Refresh values, Hide this panel |

Every row shows its current value, read with `settings.get` every 30 s and right after each click.

## Install (on the Mac, once)

```sh
git clone https://github.com/teamleaderleo/leo-workspace ~/Projects/leo-workspace   # skip if present
cmux ext add ~/Projects/leo-workspace/apps/leo-customizer
```

Accept the install card. That card lists the two scopes. The section then appears at the
bottom of the sidebar. If it shows up somewhere else, run
`cmux apps place 'local/leo-customizer#cmux.section/1' --region bottom`.

## Persistence across relaunch and updates

`cmux ext add` copies the folder into cmux's state directory (`<state>/apps/local/leo-customizer`).
That copy survives relaunches and nightly updates, because the app is not part of the cmux build.
To pick up a new version of this folder:

```sh
git -C ~/Projects/leo-workspace pull && cmux ext add ~/Projects/leo-workspace/apps/leo-customizer
```

## Turn it on and off (one step)

- Off: run `cmux apps hide local/leo-customizer`, or click **Hide this panel** at the bottom of the section, or pick palette › **Hide App…**.
- On: run `cmux apps unhide local/leo-customizer`, or pick palette › **Show Hidden App…**.
- Gone for good: `cmux ext remove local/leo-customizer`.

## Scopes

- `settings:read` shows the current values. Without it, the section says "Cannot read settings" and the rows still work.
- `actions:run` runs a row's action when you click it.

The install card asks for both scopes. If clicks do nothing, open **Settings › Apps › Leo's Customizer** and turn on both.

## What a click can and cannot do

cmux never lets an app write global settings, because `settings.set` is not offered to apps. So a row does one of two things:

- It runs a cmux action that makes the change, such as sidebar density, animations, compact list, controls on hover, spaces, vertical tabs, interface size, background or customize reset.
- If no action exists, it opens Settings scrolled to that exact setting. Theme file, accent, text sizes, chat font and most quick toggles work this way.

The "Theme file…" menu goes further: it opens a /customize chat with "Set my theme file to X" already typed.

## When an update breaks it

1. Run `cmux ext reload leo-customizer`, then check the section again.
2. Logs: `cmux raw command --request-json '{"cmd":"apps-logs","app":"local/leo-customizer"}'`.
3. A click that toasts "Could not run <action>" means that action was renamed or refused. Find its new id in `plans/cmux-next/action-surfaces.json` in cmux, and edit the id in `main.js`.
4. A row that shows "default" for everything: check Settings › Apps for the `settings:read` scope.
5. Reinstall from the folder with `cmux ext add ~/Projects/leo-workspace/apps/leo-customizer`, or hide the section (above) until it is fixed.

## Test (Linux, no Mac needed)

```sh
CMUX_APP_HOST_JS=<cmux checkout>/cmux-tui/crates/cmux-app-host/js bun test apps/leo-customizer/test
```

This runs `main.js` in cmux's own FakeHost. The test checks the manifest, checks that every
settings key is in cmux's settings schema, checks the rendered groups and values, checks which
action each click runs, and checks the refusal and no-scope paths.
