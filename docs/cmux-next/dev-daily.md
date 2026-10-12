# cmux NEXT DEV

`cmux NEXT DEV` is the rolling daily build of the current green
`feat-cmux-next` head. The build is a Release configuration with its own stable
bundle identifier, `com.cmuxterm.app.debug.next`, so its state and TCC and
Accessibility grants remain separate from cmux NIGHTLY and nightly-next.

The publisher signs the exact Release artifact with the protected Developer ID
identity and uploads `cmux-NEXT-DEV.zip` to the `cmux-next-dev` GitHub
prerelease. It deliberately skips notarization. Downloading the archive with
`curl` or `gh` keeps it outside the browser quarantine path.

From a `feat-cmux-next` checkout, update in one line (the [README](README.md#cmux-next-dev)
shows how to run it without a checkout):

```sh
bash scripts/cmux-next/update-dev-daily.sh
```

Run it as often as you like:

- **Nothing new:** when the asset's `updated_at` is the one it installed last
  (kept in `~/Applications/.cmux NEXT DEV.app.installed`), it says the app is
  up to date and doesn't touch it. If GitHub's API doesn't answer, an
  unchanged SHA-256 asset means the same. `--force` reinstalls anyway.
- **An update:** it verifies the SHA-256 asset and the bundle identifier, quits
  a running app with **Quit and Keep Sessions** (through the app's bundled
  `cmux app quit-keep-sessions`; a plain Quit may ask), atomically replaces the
  app and opens it again. Terminals keep running in their session daemons, and
  agents under acpmux, so the new build reattaches to them: workspaces, panes,
  tabs, browser pages, agents and their chats. Nothing needs relaunching or
  re-pointing. An app that wasn't running stays closed.
- **A first install:** nothing is quit, and the new app opens.

The new build takes over the previous build's daemons on its own. A `cmux-tui`
session daemon of another build is handed off to the bundled one; one of the
same build keeps running and the app reattaches to it. An acpmux of another
build, or one still running from the bundle the update replaced, is handed off
to the bundled one, and its agents keep running under their hosts.

Sparkle is disabled for this channel (`UpdateBuildIdentity.track` is
`.development`), so there is no in-app update; this script is the update path.
