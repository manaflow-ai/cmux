# Azure cmux relay service

This directory packages `cmux-relay` as an independent cmux Cloud data-plane
service. It is not the chatmux relay and it does not use Durable Objects.
This slice adds the service binary, Azure topology, and lifecycle contract. It
does not change the provider attach routes or deploy Azure resources.

The relay forwards encrypted WebSocket frames. It does not parse PTY data,
port data, browser frames, or workspace RPC data. PTY, loopback port forwarding,
and browser automation use the existing cmux remote protocol lanes over the
same connection:

| Feature | Remote service | Relay behavior |
| --- | --- | --- |
| PTY | terminal and interactive lanes | Copy opaque binary frames |
| Port forwarding | `TcpTunnel` and `Tunnel` lane | Copy opaque binary frames |
| Browser automation | `ComputerUse` service | Copy opaque binary frames |

The relay does not create browser capabilities. A machine must advertise and
serve the `ComputerUse` capability before a client can use browser automation;
the relay only carries that already-authorized traffic.

## Topology

The cmux Cloud control plane will assign each machine a stable relay shard. The
machine and every client will receive that shard endpoint. A shard has one
active relay process because its circuit pairing table is in memory. Azure
repairs that VM when it fails. A second shard provides capacity and a reconnect
target. Each fallback shard has its own issuer and HMAC secret, so the control
plane must issue a matching ticket set for every endpoint it gives to a machine
and client. The control-plane assignment and provider bootstrap are the next
integration slice.

Do not put several relay processes behind one generic load balancer. The machine
and client use different network flows, so a five-tuple hash cannot guarantee
that both reach the same process. Add a shared circuit store or a route-aware
proxy only after the protocol and failure model require it.

The Bicep template creates this path:

```text
client and VM  ->  Application Gateway (TLS/WebSocket)  ->  Standard Load Balancer
                ->  one VMSS instance  ->  cmux-relay:8787
```

Azure resource names and the public DNS label use a deterministic hash of the
resource group and shard. The relay still receives the original shard string,
so routing names can contain periods, underscores, or uppercase characters.

Application Gateway probes `/readyz`. A relay that receives `SIGTERM` changes
`/readyz` to `503`, rejects new upgrades and circuit allocations, and keeps
existing circuits alive during the drain period. The VMSS service waits up to
five minutes before it exits. Application Gateway can drain WebSockets for up
to one hour.

This follows the process boundary described in [exe.dev's connection handoff
design](https://blog.exe.dev/adding-features-without-interrupting-network-connections):
the process that owns live connections has a separate lifecycle from the code
that decides routing. This first slice implements the lifecycle and drain
boundary. It does not yet transfer live file descriptors between two relay
processes. A whole VM failure always drops live TCP connections; remote session
resume reconnects them.

## Security

The cmux Cloud API remains the identity authority for the integration. It will
check Stack ownership and team access, then issue short-lived, slot-bound
Register and Connect tickets. The relay verifies those tickets with an HMAC
key. The key is stored in Azure Key Vault. The VM receives it at service start
through a VM-only managed identity and keeps it in `/run/cmux-relay/relay.env`
with mode `0640`, readable only by the relay service account and its group.

The existing vault must use Azure RBAC authorization. The template creates a
separate managed identity for Application Gateway and scopes it to only the TLS
certificate secret. The VM identity is scoped to only the relay HMAC secret.
Check the vault before deployment:

```sh
az keyvault show --name <key-vault> \
  --query properties.enableRbacAuthorization --output tsv
```

The command must print `true`. The template does not create legacy access
policies.

The relay never receives a user's Stack token and has no chatmux organization
dependency. The Noise session above the relay authenticates the enrolled device
and protects application bytes from the relay operator.

Port forwarding is loopback-only in the VM. There is no static port allowlist
in this first release. An authenticated client must make a `CreateRoute`
request for a port, and the VM daemon dials `127.0.0.1:<port>`. The relay does
not open a listener on that port. Public preview URLs remain a separate,
explicit share operation.

Do not place tickets in logs, URLs, image metadata, or invitation route hints.
Invitation files and ticket files must stay owner-readable. Use an immutable
binary URL and SHA-256 digest in production.

## Build

The Azure VM installs the x86_64 musl binary published by the existing
`cmux-tui-artifacts` workflow. After that workflow publishes a commit, read the
binary digest from its immutable manifest:

```sh
curl -fsSL https://files.cmux.com/cmux-relay/<commit>/manifest.json | jq
```

Construct `relayBinaryUrl` as
`https://files.cmux.com/cmux-relay/<commit>/cmux-relay-x86_64-unknown-linux-musl`.
Set `relayBinarySha256` to the matching `binaries` digest from the manifest.
The cloud-init script accepts only immutable
`files.cmux.com` commit paths and verifies the digest before systemd starts the
service. The `Dockerfile` remains available for a local smoke test. TLS
terminates at Application Gateway.

## Deploy one shard

Create two separate resource groups, preferably in different Azure regions,
and deploy this template once per shard. Keep `vmssCapacity=1`.

1. Store the relay HMAC secret and a versioned TLS certificate secret in the
   existing Key Vault. The HMAC secret must contain at least 32 random bytes.
   Set `certificateSecretName` to the TLS secret name used in
   `certificateSecretId`.
2. Copy `bicep/shard.parameters.example.json` to a private parameters file.
   Set `relayBinaryUrl` to the immutable artifact path described above and set
   `relayBinarySha256` to its `binaries` digest from the manifest. Set the
   certificate secret ID to a versioned Key Vault secret ID. Set
   `availabilityZone` to `1`, `2`, or `3` only when the selected region
   supports that zone. Keep it empty for a non-zonal region.
3. Deploy without putting secret values on the command line:

```sh
az deployment group create \
  --resource-group <relay-shard-resource-group> \
  --template-file relays/azure/bicep/shard.bicep \
  --parameters @relays/azure/bicep/shard.parameters.private.json
```

The output `relayRoute` is the route to publish in the cmux relay catalog. Add
a CNAME such as `relay-westus2-a.cmux.cloud` to the output hostname. DNS changes
are outside this template.

The Bicep deployment grants each identity the Azure Key Vault Secrets User role
at its individual secret scope. Role propagation can delay the first service
start. The pre-start loader uses bounded network retries, and systemd retries a
failed service start.

## Upgrade and failure behavior

Use an immutable binary digest and a rolling VMSS model update. Before a
planned replacement, systemd sends `SIGTERM` to the relay. The relay marks
itself not ready, Azure stops sending new traffic, and existing sockets drain.
Clients retry with unlimited attempts by default, exponential backoff from
100 ms to 5 seconds, jitter, and heartbeats. The daemon retains replayable
remote lanes for its resume lease and replays them after reconnect. Tunnel
streams are not replayed after a disconnect because repeating a TCP write can
have an external side effect.

If the VM or its region fails, the relay loses its in-memory circuit table. The
control plane will assign the machine a healthy shard during reconnect. No
external queue carries PTY or tunnel bytes, so a broker outage cannot replay or
expose application data.

## Local smoke test

Run the local image with an explicit secret and a loopback bind:

```sh
docker run --rm -p 127.0.0.1:8787:8787 \
  -e CMUX_RELAY_HMAC_SECRET="$(openssl rand -hex 32)" \
  -e CMUX_RELAY_BIND=0.0.0.0:8787 \
  -e CMUX_RELAY_SHARD=local \
  cmux-relay:dev serve
```

The image defaults to a loopback bind and refuses an unauthenticated
non-loopback bind. The command above supplies a test secret before widening the
container bind to `0.0.0.0`.

Check both endpoints:

```sh
curl -fsS http://127.0.0.1:8787/healthz
curl -fsS http://127.0.0.1:8787/readyz
```

No Azure resources are created by this change. Provider bootstrap, shard
catalog assignment, and cmux API ticket issuance are the next integration
slice.
