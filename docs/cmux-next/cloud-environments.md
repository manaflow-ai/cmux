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
(#45790, `scripts/cmux-next/cloud-dev-stack.sh`). HTTPS only, no path, user or query.

The stack runs all three Workers a dev build talks to, from the tag's own tree: the cmux API
(`backend/apps/api`) at the origin's port P, the mobile Worker (`cmux-next-ios/backend`) at P+1 and
the device hub (`workers/device-hub`) at P+2, in one workerd session behind a generated front
Worker. The API origin is the only one a build is given:

- the Mac reads the other two from the stack's `/v1/client-config` (the front answers it with the
  stack's own `mobile_origin` and `device_hub_origin`). A client-config may name the same tailnet
  host on another port, never another tailnet host. With no cached client-config for a tailnet
  origin, the launch fetches it (up to 5 s) instead of starting on the development table, so the
  Mac registers with the stack's mobile Worker from its first launch;
- the iPhone app derives them (`CloudBackendOverride.mobileAPI` and `deviceHub`: the next two ports
  of a tailnet origin), unless a rig's `CMUX_MOBILE_API_BASE` or `CMUX_MOBILE_DEVICE_HUB_URL` names
  one. The shared development deployment and previews keep the build's own services.

The stack's data follows the build space rules: its Durable Objects (the API's, the mobile Worker's
team hubs, the hub's users and sessions) are its own; Postgres and Vitess (the mobile Worker's
`mobile_*` tables included) are the shared `development` branches, or the tag's own
`lane-wd-<tag>` branch when the tree adds a migration (`backend/db/migrations` or
`backend/db/drizzle-mysql`). A stack has no TURN keys, APNs keys or Slack token: no relay ICE and no
push from it.

A stack lives as long as a dogfooded build may use it. Every stack port goes through the VM's router
(`scripts/cmux-next/cloud-dev-stack/router.mjs`). After 2 h with no request, the stack's workerd
stops but keeps its files, Durable Object data, credentials and ports. Its next request wakes it:
the router holds that request until the stack answers, about 6 s when measured, so a build opened
the next day finds its backend where it left it.

The VM runs at most 16 stacks and keeps its memory and disk floors. A start or wake that does not
fit stops the least recently used running stack. A stack is released 7 days after its last `up`,
or earlier, least recently used first, when more than 48 are stopped or disk runs short. After
that its origins stop answering (Serve is off for its ports) until the next `up` of the tag, and
`cloud-dev-stack.sh status` shows it released. `cloud-dev-stack.sh stop --tag T` stops a stack by
hand.

A stack can also have a public origin, so a phone off the tailnet reaches it:
`https://api.s<N>.wdev.cmux.dev` and its slot's `mobile.` and `hub.` hosts. `up` gives each stack a
free slot and prints it (`Public:`), and `cloud-dev-stack.sh url --tag T --public` reads it back.
The Worker `cmux-wdev-gateway` answers those hosts and admits a request only with a signed-in cmux
team account's token, or a token the stack itself issued. It then sends the request through a
Cloudflare Tunnel to the VM's router. Details and threat model: `cmux-next-ios/SECURITY.md`, "A
tag's own Cloud backend".

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
for a tag and prints a `Backend:` line with what the Mac app reports; with `tag-stack`, the phone's
readiness receipt must also name the stack's mobile Worker (`api_base_url`).
