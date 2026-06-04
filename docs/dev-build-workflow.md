# DEV build workflow

A repeatable recipe for cutting a tagged `cmux DEV <tag>.app`, packaging it as a
drag-and-drop `.dmg`, and keeping the local checkout in sync with the public
release's new features — without ever touching `/Applications/cmux.app`.

## Why this exists

- The public release is whatever is shipped via `releases/latest/download/cmux-macos.dmg`
  and installed at `/Applications/cmux.app` (bundle ID `com.cmuxterm.app`).
- The DEV build is what you get from `./scripts/reload.sh --tag <name>`. Its bundle
  ID is `com.cmuxterm.app.debug.<tag>`, so it has its own UserDefaults, keychain,
  socket path, and Sparkle appcast state. **DEV must not live in `/Applications`**
  or it collides with the release.
- The DEV build's purpose is to (a) dogfood WIP changes, (b) let you cherry-pick
  release-only features locally and try them before the public sees them, and
  (c) produce a draggable artifact you can hand to yourself for testing outside
  the dev machine.

## Build, mirror, package

```bash
# 1. Cut a tagged DEV build. The .app ends up in DerivedData as before.
./scripts/reload.sh --tag <short-name>

# 2. The same .app is also copied to ~/Downloads/cmux-dev/cmux DEV <short-name>.app
#    (see "Mirror" below).

# 3. Wrap it as a draggable .dmg, output to ~/Downloads/.
./scripts/package-dev-dmg.sh                  # uses the newest .app in ~/Downloads/cmux-dev/
# or
./scripts/package-dev-dmg.sh --tag <short-name>
# or
./scripts/package-dev-dmg.sh --app /path/to/cmux\ DEV\ <short-name>.app
```

The dmg is read-only, contains an `Applications` symlink, and a `README.txt`
that warns the user not to drag the .app into `/Applications`.

## Mirror

`reload.sh` mirrors the tag build's `.app` to `~/Downloads/cmux-dev/`. This
exists so you can:

- See the artifact in Finder without spelunking through `DerivedData/`.
- Hand the .app to `package-dev-dmg.sh` without re-deriving paths.
- Keep a personal archive of DEV builds (delete manually when you don't need
  them; the directory is plain files, no symlink magic).

The mirror is opt-out via `CMUX_SKIP_DOWNLOADS_MIRROR=1` and skipped if
`~/Downloads` doesn't exist.

## Install / run the packaged DEV build

After opening the dmg:

1. **Do not** drag `cmux DEV <tag>.app` into `/Applications`.
2. Recommended drop targets:
   - `~/Applications/` (create if it doesn't exist; Launch Services picks it up).
   - `~/Downloads/cmux-dev/` (where it was mirrored from).
   - Anywhere on `~/Desktop`.
3. Open from Finder. The DEV build runs side-by-side with the public release
   because their bundle IDs differ.

To watch the live debug log for a tagged build:

```bash
tail -f /tmp/cmux-debug-<tag>.log
```

## Pulling new release features into the local DEV

The local repo's `main` branch is the source of truth for upstream. The
checked-out work branch is where you do your own work.

```bash
# Sync main with upstream's latest.
git fetch origin
git rebase origin/main             # or: git pull --rebase origin main

# Cherry-pick a specific upstream feature into your work branch.
git cherry-pick <commit-sha>

# Rebuild DEV with the new commit included.
./scripts/reload.sh --tag <short-name>
./scripts/package-dev-dmg.sh --tag <short-name>
```

For multi-commit features:

```bash
git fetch origin
git log --oneline origin/main ^HEAD   # see what's new
git cherry-pick <sha1> <sha2> <sha3>
```

## Tracked files

- `scripts/reload.sh` — emits the tagged `.app` and mirrors it to
  `~/Downloads/cmux-dev/`.
- `scripts/package-dev-dmg.sh` — wraps a `.app` into a draggable `.dmg` in
  `~/Downloads/`.
- `Sources/Update/UpdateController.swift`,
  `Sources/Update/UpdateDelegate.swift` — DEV builds skip the launch + hourly
  background Sparkle probe and the `didFindValidUpdate` -> sidebar pill path,
  so the public release appcast does not confuse a tagged DEV into a "you're
  behind" notification.

## Cleanup

The script never deletes old DEV builds or old dmgs. Remove manually:

```bash
rm -rf ~/Downloads/cmux-dev/cmux\ DEV\ <tag>.app
rm ~/Downloads/cmux-dev-<tag>-<sha>.dmg
```
