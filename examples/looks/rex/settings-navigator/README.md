# Rex settings navigator

An opt-in New Tab page that lists all 85 of Rex's preference actions (the Settings group
of its Mac actions reference: notifications, interface, themes, terminal, remote hosts,
developer). Each row says
how the action maps to cmux:

- **Exact**: the cmux setting does the same thing. Click or Return opens Settings at it.
- **Related**: the nearest cmux setting, with a different behavior. The row opens it and its
  subtitle says how it differs.
- **Unavailable**: cmux Settings has no such control. The row opens nothing; its subtitle (and
  a click) says where the behavior lives instead, usually a Ghostty config key, since cmux's
  terminals read Ghostty config.

Rows open Settings through the public `openSettings` action with a `setting` key, the same
call as `cmux action run openSettings --setting KEY`. Nothing here changes a setting by
itself; the page only navigates.

## What it sets

| Setting | Value | Why |
| --- | --- | --- |
| `tabs.newTabApp` | `local/customize` | New Tab shows this page |
| `tabs.nativeNewTabPage` | `false` | so the app's page is used |

The page needs the `actions:run` scope to open Settings: turn it on for
`local/customize` in Settings > Apps once. Until then a row shows "Could not open Settings".

## Install, preview and undo

From a checkout:

```sh
cmux customize use examples/looks/rex/settings-navigator/profile.json
cmux customize check
```

Open a new tab (Cmd-T): the page lists the 85 actions with All, Exact, Related and
Unavailable filters and a search over titles, Rex ids and cmux keys. Keep it with
`cmux customize apply`, or undo the preview with `cmux customize discard`.

This replaces any other `local/customize` app (for example the Rex sessions page): they
share the one customize folder.

## Editing

`mapping.json` is the source. After editing it, run

```sh
python3 examples/looks/rex/settings-navigator/build.py
```

It checks that there are 85 actions and that every named key is a visible cmux Settings
row, then rewrites the data block in `customize/main.js`, `profile.json` and the tables
below. `build.py --check` only reports what is stale.

## Mapping

<!-- BEGIN TABLES -->
<!-- END TABLES -->
