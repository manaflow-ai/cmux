# Tagged Builds

Tagged builds isolate app name, bundle ID, debug socket, and DerivedData path so multiple agents and the user's normal app do not collide.

```bash
./scripts/reload.sh --tag <tag>            # build only (default)
./scripts/reload.sh --tag <tag> --launch   # build, then open
```

After a successful build `reload.sh` terminates any running app with the same tag, so opening the printed app path launches the fresh binary.

## App path links

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use it to confirm the tag built, but link the build in chat as `http://127.0.0.1:17320/<tag>` through the local Tag Opener. Never put a `file://` URL, a raw `.app` or DerivedData path, or a `/tmp/cmux-<tag>/...` link in chat output.

## Tagged CLI and socket

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, uses the matching tagged CLI from DerivedData, scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for that tag.

`/tmp/cmux-cli` points at the most recently reloaded build and can target the user's main app socket, so it is never safe for tagged dogfood.

## Cleanup

Before launching a new tagged run, quit older tagged apps you started this session and remove their stale `/tmp` sockets. Remove derived data only when no active task needs it.
