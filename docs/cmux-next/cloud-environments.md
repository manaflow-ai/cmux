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
use `cloud env set` to change it. The state is stored atomically in
`~/Library/Application Support/cmux/<bundle-id>/cloud-environment.json`.
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
