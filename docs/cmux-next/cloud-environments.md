# NEXT Cloud environments

One NEXT app can select a backend without rebuilding. Use the `cmux` bundled
with that app, or the CLI in one of its terminals:

```sh
cmux cloud env get --json
cmux cloud env set staging --json
```

Names are `local`, `dev`, `preview-N` (a positive pull request number),
`staging`, and `prod`. DEV bundles default to `dev`; the NEXT nightly defaults
to `prod`. Only DEV and NEXT nightly bundles can change the selection.
Release and RC always resolve production, including when a launch variable
or an old state file names something else.

`CMUX_NEXT_CLOUD_ENV` seeds a bundle's first launch. Once a selection exists,
use `cloud env set` to change it.
A cmux app exports its own `CMUX_NEXT_CLOUD_RUNTIME`, `CMUX_NEXT_CLOUD_ENV` and
`CMUX_NEXT_CLOUD_BACKEND` to its terminals. An app opened from another cmux's
terminal ignores them, so a DEV build started from a NIGHTLY shell keeps its
own selection. To pick a backend for a launch from inside a cmux terminal, pass
`--cloud-backend NAME` (`open -g APP --args --cloud-backend staging`), or set
`CMUX_BUNDLE_ID` to the launched app's bundle id beside the variable. The state is stored atomically in
`~/Library/Application Support/cmux-next/<bundle-id>/cloud-environment.json`
(builds before kept it in classic cmux's `cmux/<bundle-id>`; it moves once).
The JSON result includes every selected origin, the bundle, and the state path.

Setting the environment saves it even when the app is closed. With a running
app that supports the switch, it tears down its Cloud connections and restarts
the app and daemon while keeping terminal hosts alive. `restart_scheduled`
reports that acknowledgement; otherwise restart the selected app yourself.
Switching environments requires a fresh Cloud sign-in. Auth storage is scoped
to the bundle, environment, and selection revision; Cloud caches and install
identities are scoped to the environment.

The Rust `cmux-cloud-environment` crate owns the deployment table. Preview APIs
use `https://cmux-api-preview-N.debussy.workers.dev` with development auth and
platform services. Share links use development install tokens because the
development share room verifies that issuer. A preview does not redirect those
tokens to another Worker.

NEXT nightly sharing follows its selected environment (production by default),
including the matching production issuer. A nonempty `CMUX_SHARE_ROOM_URL`
does not override NEXT's selection; an empty value still disables sharing.
Classic builds retain their existing override and deployment behavior.

Local development uses explicit loopback ports: API `8787`, platform `8788`,
VM `8789`, mobile `8790`, device hub `8791`, and auth web `3777`. Start the
corresponding local services on these ports before selecting `local`; the
switch does not start or deploy a backend. Development and staging use the
development mobile and device hub services until those services have separate
staging deployments.

Development connects GitHub with its own App, `cmux-cloud-dev`, and finishes connects on the
staging console: [cloud-dev-github-app.md](cloud-dev-github-app.md).

## A dev build's own backend (a tag's stack)

A DEV bundle (`com.cmuxterm.app.debug`, `com.cmuxterm.app.debug.<tag>`) can also use a tailnet
origin, `https://<host>.<tailnet>.ts.net[:port]`: one tag's `wrangler dev` stack on the dev VM
(#45790). Its API is that origin; its other services are the development deployment's until its
`/v1/client-config` names others, which may be the same tailnet host on another port and never
another tailnet host. HTTPS only, no path, user or query.

The tag's hand-off writes the choice next to the selection state, in
`~/Library/Application Support/cmux-next/<bundle-id>/backend.json`
(`{"backend": "<origin or name>"}`), so every launch of that tag uses it, from the Tag Opener
too, with no rebuild. The order is:

1. the launch's `--cloud-backend`, then `CMUX_NEXT_CLOUD_BACKEND`, then `CMUX_NEXT_CLOUD_ENV`;
2. the DEV bundle's `backend.json`;
3. the picker's persisted choice (`cloud env set`);
4. the bundle's default (`dev`).

`backend.json` and tailnet origins are read only by DEV bundles: NIGHTLY, RC and Release never
look for the file, and refuse a tailnet origin from any source. A malformed file, or one naming
anything outside the allowlist, fails closed: the launch reports the Cloud unavailable and why. A
`backend.json` choice never rewrites the picker's state (`cloud env get --persisted` ignores it),
and like any launch override it has its own sign-in storage.

The app says which backend it uses: Settings > Accounts, under the cmux account, reads
"Cloud backend: <origin> (this tag's backend.json)" in a DEV or NIGHTLY build, and the control
socket's `auth.status` has `backend` and `backend_label` (the same line); the CLI's
`cloud env get --json` names `backend_override` (`launch` or `tag_file`) when one applies.

The cmux-next iPhone app takes the same choice as `CMUX_NEXT_CLOUD_BACKEND` at launch (DEBUG
builds only) and keeps it for later launches; an empty value clears it. Settings > Developer shows
it as "Cloud backend". `cmux-next-ios/scripts/review.sh --backend <origin|tag-stack|dev>` sets both
for a tag and prints a `Backend:` line with what the Mac app reports.
