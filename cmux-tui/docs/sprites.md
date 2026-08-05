# Fly Sprites

Fly Sprites can host a persistent remote cmux session on a normal ext4
filesystem. The base checkpoint contains the pinned `cmux` npm distribution
and a Sprite service, but deliberately excludes every daemon identity,
invitation, client key, and provider credential.

## Build the base checkpoint

Install the Sprite CLI, source an owner-only token file, and run:

```sh
set -a
source ~/.secrets/fly-sprites.env
set +a
cmux-tui/scripts/build-sprite-base.sh --org manaflow
```

The script prints the Sprite name and checkpoint id. It leaves the `cmux-tui`
service stopped and `/home/sprite/.local/share/cmux-sprite/remote` absent.
Starting the service after a new Sprite is provisioned generates a unique
daemon identity.

Checkpoints currently restore one Sprite. Fly's cross-Sprite drive forking is
in beta and is not exposed by the public REST API. Until that API ships, this
checkpoint is a verified base artifact rather than a generally available
create-time template.

## Authentication boundary

There are two independent trust planes:

1. The cmux backend owns `SPRITE_TOKEN` and uses it for Sprite lifecycle,
   service, filesystem, and exec APIs. The token never enters a Sprite, native
   client, command argument, checkpoint, or database row.
2. Native clients connect directly through the public Sprite HTTPS edge, but
   cmux authenticates the daemon key and device key inside an end-to-end Noise
   session. The public URL is an untrusted carrier, not an authorization
   boundary.

Do not put a static `--ws-token` in the checkpoint. Do not checkpoint
`/home/sprite/.local/share/cmux-sprite/remote`; clones would share the daemon
private key and enrolled-device database.

## Provision and enroll one client

Start the service after provisioning:

```sh
sprite exec -o <org> -s <sprite> -- sprite-env services start cmux-tui
```

Fetch the Sprite URL through the authenticated management API. Create a
single-device, short-lived invitation inside the Sprite:

```sh
cmux enroll create \
  --session sprite \
  --state-dir /home/sprite/.local/share/cmux-sprite/remote \
  --advertise wss://<sprite-host>/v1/link \
  --ttl 300 \
  --json
```

The backend returns the invitation once to the already authenticated cmux
user. The native client stores it in an owner-only file, claims it with its
persistent device key, and waits:

```sh
cmux connect \
  --invite-file ~/.config/cmux/sprite.invite \
  --device-name <device-name>
```

The backend then runs `cmux enroll pending` through authenticated Sprite exec.
It approves only the invitation id it issued for that user, VM, and expiry.
Never approve every pending request, and never identify a claimant only by its
display name.

After approval, the client reconnects with its device key. The invitation is
single-device and expires after five minutes. Revocation uses `cmux enroll
revoke`; it closes live sessions and rejects the device in the future.

For a team-owned Sprite, authorize invitation creation and approval against
the exact team and VM row before any provider call. Record the issued
invitation id, user id, VM id, expiry, and final device fingerprint. Store no
invitation URI or Sprite token.

## Why the URL is public

The current native WebSocket client does not attach a Fly organization token.
Keeping the Sprite URL private would require a cmux backend relay that adds the
provider credential. A public URL avoids that relay and preserves direct
interactive latency. Unauthenticated callers can reach the WebSocket edge but
cannot complete cmux's Noise handshake or access mux data.

If direct public carriers are unacceptable, implement a machine-provider
stream that keeps `SPRITE_TOKEN` server-side and forwards opaque cmux protocol
messages. Do not send the provider token to the native client.
