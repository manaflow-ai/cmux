# Tagged Builds

Tagged builds isolate app name, bundle ID, socket, and DerivedData path so multiple agents and the user's normal app do not collide.

## Reload

Use:

```bash
./scripts/reload.sh --tag <tag>
```

`reload.sh` builds but does not launch by default. It terminates any running app with the same tag after a successful build, so opening the printed app path launches the fresh binary.

Use:

```bash
./scripts/reload.sh --tag <tag> --launch
```

only when the task requires launching.

## App path links

`reload.sh` prints:

```text
App path:
  /absolute/path/to/cmux DEV <tag>.app
```

Build chat links from that exact path. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode DerivedData paths and never use `/tmp/cmux-<tag>/...` app links in chat output.

## Tagged CLI and socket

For CLI or socket dogfood against a tagged Debug app, use:

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

Do not use `/tmp/cmux-cli` for tagged dogfood. That symlink points at the most recently reloaded build and can target the user's main app socket.

The helper:

- refuses to run without `CMUX_TAG`
- targets `/tmp/cmux-debug-<tag>.sock`
- uses the matching tagged CLI from DerivedData
- scrubs ambient cmux terminal context
- sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH`

## Cleanup

Before launching a new tagged run, clean up older tags started in the same session:

- quit old tagged app
- remove its `/tmp` socket if stale
- remove derived data only when you are sure no active task needs it

Do not open an untagged `cmux DEV.app` from DerivedData. It shares the default debug socket and bundle ID with other agents.
