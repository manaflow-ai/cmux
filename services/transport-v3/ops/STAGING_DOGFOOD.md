# v3 staging and Apple dogfood

The staging control service is currently live at the operator-provided HTTPS
origin. Keep this preflight read-only and run it against the intended database
branch before building clients:

```sh
python3 services/transport-v3/ops/staging_preflight.py \
  --control-url https://cmux-v3-control.proudforest-1b685104.eastus.azurecontainerapps.io \
  --subscription a428770c-842f-42b8-b23c-cabe9003b47c \
  --database cmux-prod --branch staging --org cmux \
  --receipt artifacts/transport-v3/staging-preflight.json
```

The command checks `/readyz` and `/healthz`, confirms that the Azure Container
App has the required non-secret environment names and secret bindings, and
reads the five v3 tables plus relay/device counts from PlanetScale. It never
prints secret values or changes Azure, Stack, or PlanetScale. Add
`--require-device` when the control service and relays are ready and a dogfood
run must already have an enrolled device.

Current staging evidence: the control service responds HTTP 200 on both health
routes, PlanetScale `cmux-prod/staging` contains the v3 tables, and two active
relay registrations have feed-token hashes. The database currently has zero
enrolled devices, so client dogfood cannot pass enrollment until a Mac or
simulator registers through the control API.

The intended Apple run is one short, unique tag shared by the tagged Mac DEV
host and an isolated iOS Simulator. Authenticate the Mac with the `personal`
dogfood profile and the Simulator with the `agent` profile from
`~/.secrets/cmuxterm-dev.env`; never mix profiles. Exercise enrollment,
directory publication, direct and relay session setup, renewal, revocation,
reconnect, sign-out, and all six lanes. A simulator build is not evidence of
physical-device behavior, NAT traversal, suspended-app recovery, or relay
handover.

The controller build fleet currently exposes validated `cmux` and `chromium`
recipes only. Its historical `ios-simulator` jobs are not a supported current
submission contract, so do not submit an iOS job by guessing a recipe or worker.
Use the provisioned iOS recipe only after the fleet operator publishes its
current `cmux-ci submit --help` contract and artifact/install instructions. The
Mac build can use the normal exact-SHA `cmux-ci build cmux` path, but this does
not prove iOS compilation, signing, installation, pairing, or v3 runtime
behavior.

Production remains blocked until the v3 composition replaces the current iroh
path, a non-empty relay circuit survives a drain with replayed application data,
and physical iPhone plus Mac tests prove renewal, revocation, reconnect and
sign-out. Do not promote the staging control image or write the production
branch as part of dogfood.
