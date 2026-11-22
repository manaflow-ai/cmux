# cmux Helper: one app for Screen Sharing and Computer Use permissions

cmux Helper is the build's one permission app: its Screen Sharing helper, `<app> Screen
Sharing.app` (`<app id>.screen-sharing`, plans/cmux-next/screen-sharing-helper.md). It holds
macOS's Screen Recording and Accessibility for both Screen Sharing and Computer Use, so a grant
restarts only the helper, never the cmux app. Every Release, NIGHTLY and DEV build carries it, and
`scripts/ci/check-screen-share-identity.sh` fails a signed build with any other app in
`Contents/Library`.

It replaced cmux Remote, a separately signed bundle the daemon supervised. No build embedded that
bundle any more, so its supervisor, `remote-host-*` daemon commands, `cmux remote-host` CLI and
`remote_*` MCP tools are gone.

## Processes

```
cmux.app
  └─ cmux-tui daemon
       └─ <app> Screen Sharing.app/Contents/MacOS/cmux-screen-sharing
            ├─ cmux.rd/1 host for Screen Sharing (one per session)
            └─ __computer-use-worker (cmux-tui-core computer_use_host/macos.rs)
```

The helper runs from a verified copy outside the app bundle, spawned with responsibility
disclaimed, so macOS checks its own grants (plans/cmux-next/screen-sharing-helper.md).

## Grants

- The app asks the helper for its grants (`MacScreenHelper.permissions()`) and reports them, with
  the name System Settings lists the helper under, to the daemon as `helper-config` at each daemon
  connect and when the app becomes active (`CmuxHelperService`). The daemon keeps them in memory
  only.
- `helper-status` (capability `helper-v1`, cmux-tui/spec/commands.md) shows them to any local
  connection; the verified app also gets the Computer Use worker's status.
- `cmux helper grants` reads them and prints what to fix; `cmux helper open-settings KEY` opens
  the System Settings pane.

## CLI and MCP

- `cmux helper status | open-settings | share on|off [--device D] | grants | access | stop`.
- MCP: `helper_status`, `helper_share`, `helper_set_access`, `helper_stop_session`. Changing a
  device's access goes through the app's confirmation.

## Follow-ups

- The helper's display name is still `<app> Screen Sharing`; renaming it to `<app> Helper` is a
  separate change (the bundle id `<app id>.screen-sharing` stays).
- The Computer Use worker reports no agent activity to the app yet, so the menu bar lists no
  Computer Use sessions and `computer-use-activity` is not published.
- `remote.endSharingOnQuit` is read by nothing until it is wired to the helper or retired.
