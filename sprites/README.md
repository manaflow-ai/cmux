# cmux Sprites

`cmux-sprites` creates and controls Fly Sprites through the authenticated
cmux.com backend. The CLI receives Stack access and refresh tokens, but never
receives a Fly token. Sprite ownership, billing-team checks, provider calls,
and lifecycle state remain in the existing Cloud VM control plane.

```sh
cd sprites
go build ./cmd/cmux-sprites
./cmux-sprites login
./cmux-sprites create
./cmux-sprites list
./cmux-sprites connect <sprite-id>
```

Login prints a URL and an eight-character code. Browser opening is opt-in with
`login --open`; no localhost callback is started. Credentials are written to
`~/.config/cmux-sprites/auth.json` with mode `0600`.

Credential-bearing requests require HTTPS. Local Next.js development may opt
into loopback HTTP with `CMUX_SPRITES_ALLOW_INSECURE_LOCALHOST=1`; non-loopback
HTTP and cross-origin redirects always fail closed.

`connect` asks the owned Sprite daemon for a five-minute, one-device
invitation, writes it to an owner-only temporary file, launches `cmux
connect`, and approves only that invitation after its device claim appears.
The public Sprite URL carries the end-to-end Noise session. It is not the
authorization boundary.

## Templates

The public Sprites API does not currently expose a reusable template or
cross-Sprite checkpoint restore operation. Fly has an admin-console fork
workflow that copies a Sprite drive at a timestamp, but its public REST and SDK
contract is not documented.

Until Fly publishes that contract, cmux creates a normal Sprite and installs a
pinned `cmux` npm package before registering the persistent service. The
provider image manifest records that package as the reproducible bootstrap
input. A future fork implementation should replace only the provider create
step; Stack ownership, database idempotency, enrollment, and client auth stay
unchanged.
