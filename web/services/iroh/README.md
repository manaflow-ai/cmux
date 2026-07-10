# Iroh trust broker

The broker is scoped to the authenticated Stack `user.id`. Team membership and
the legacy team device registry never grant Iroh discovery or pairing access.

Registration challenge signatures are currently the only accepted path-hint
mutation. A Stack bearer alone cannot update hints. Address churn therefore
requires a fresh five-minute registration challenge until
`endpoint-signed-monotonic-watch-addr-update-v1` adds a dedicated signed update
route with an endpoint-owned sequence number. Endpoint or identity-generation
replacement also requires explicit revocation and reapproval; a signature from
only the proposed new key cannot replace an active binding.

`relay_fleet` is the server-configured connection preset/allowlist. It is not a
peer address. Each peer's `relay_url` hints come from its signed `watch_addr`
payload and must match that allowlist.

Discovery runs the user-scoped retention cleanup before reading. It removes
expired hints from binding JSON, challenges more than 24 hours past expiry or
consumption, and pair/relay audit rows more than 30 days beyond their useful
window. Revocation clears hints immediately. Once a revoked binding is at least
30 days old and its pair/relay audit rows have reached their own retention
limit, cleanup deletes the binding's EndpointID, device/app UUIDs, tag, and
display name. The hourly `/api/internal/iroh/retention` cron applies the same
policy across inactive accounts; responses also filter expired hints
defensively.

Postgres advisory locks make the authoritative limits concurrency-safe: six
challenges per device per ten minutes, 32 outstanding challenges per account,
32 active bindings per account, eight active bindings per physical device, 60
pair grants per account per hour, three relay mints per endpoint per ten
minutes, 12 relay mints per endpoint per day, and 100 relay mints per account
per day. The optional Vercel Firewall rule is defense in depth. A tagged-build
device-limit override requires a server flag, an exact authenticated user-id
allowlist match, and an exact deployment-environment allowlist match; it never
raises the 32-binding account limit and records an audit marker on the binding.
