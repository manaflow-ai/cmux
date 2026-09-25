# Tagged Builds

Tagged builds isolate app name, bundle ID, debug socket, and DerivedData path so multiple agents and the user's normal app do not collide.

```bash
./scripts/reload.sh --tag <tag>            # build and replace same-tag runtime
./scripts/reload.sh --tag <tag> --launch   # build, then open
./scripts/reload.sh --tag <tag> --build-only # validate without replacing the running app
```

After a successful build `reload.sh` terminates any running app with the same tag, so opening the printed app path launches the fresh binary.
Use `--build-only` only for an explicit compile/validation pass. It leaves the running tagged app, `cmuxd`, and tag state untouched, and stages the new bundle separately; the active app remains on its previous revision.

Other local variants: `reloadp.sh` (Release), `reloads.sh` (isolated Release staging) and `reload2.sh --tag <tag>` (both).

For prebuilt GhosttyKit, run `./scripts/download-prebuilt-ghosttykit.sh` (it verifies the pinned artifact), then use `CMUX_GHOSTTYKIT_PREPROVISIONED=1` with the tagged reload.

## Compile-only checks

Reuse the tag's DerivedData; a different path starts a cold build:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>" build
```

`<tag>` is the slug `reload.sh` makes: lowercase, with runs of other characters replaced by `-` (`Fix/ABC-1` becomes `fix-abc-1`). When GhosttyKit itself needs rebuilding:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## App path links

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use it to confirm the tag built, but link the build in chat as `http://127.0.0.1:17320/<tag>` through the local Tag Opener. Never put a `file://` URL, a raw `.app` or DerivedData path, or a `/tmp/cmux-<tag>/...` link in chat output.

## Tagged CLI and socket

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, uses the matching tagged CLI from DerivedData (or, for a fleet build restored with `publish-hq`, from `~/Library/Application Support/cmux/tag-app-cache`), scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for that tag.

`/tmp/cmux-cli` points at the most recently reloaded build and can target the user's main app socket, so it is never safe for tagged dogfood.

## Cleanup

Before launching a new tagged run, quit older tagged apps you started this session and remove their stale `/tmp` sockets. Remove derived data only when no active task needs it.
