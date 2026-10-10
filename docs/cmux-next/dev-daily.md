# cmux NEXT DEV

`cmux NEXT DEV` is the rolling daily build of the current green
`feat-cmux-next` head. The build is a Release configuration with its own stable
bundle identifier, `com.cmuxterm.app.debug.next`, so its state and TCC and
Accessibility grants remain separate from cmux NIGHTLY and nightly-next.

The publisher signs the exact Release artifact with the protected Developer ID
identity and uploads `cmux-NEXT-DEV.zip` to the `cmux-next-dev` GitHub
prerelease. It deliberately skips notarization. Downloading the archive with
`curl` or `gh` keeps it outside the browser quarantine path.

From a checkout, update in one line:

```sh
bash scripts/cmux-next/update-dev-daily.sh
```

The updater verifies the rolling SHA-256 asset and the bundle identifier,
asks the running app to quit through its normal app quit path, then atomically
replaces the app. Sparkle is disabled for this channel; an automatic updater
can be added later without changing the publication contract.
