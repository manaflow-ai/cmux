# Cloud trigger guest identity

`cmux host cloud identity` asks the running system host for its current public
enrollment identity. On Linux, `cmux_host::identity::query()` is the same client.
Neither accepts a socket-path, root-directory or environment override.

```json
{"machine":"vm_…","instanceId":"provider-instance-id","guestKey":"sha256:…"}
```

`guestKey` is SHA-256 of the DER SubjectPublicKeyInfo of the existing P-256
install key (id-ecPublicKey / prime256v1, uncompressed point), lowercase hex.
It is not a credential. No install token, grant or private key leaves the host.

The fixed Unix socket is `/run/cmux-host/identity.sock`, root-owned, mode 0660
for the Cloud work user's group. Connecting is the request; the host accepts
before making a new observation through its sole provider metadata reader.
After the identity state machine processes that observation, the host returns
one JSON line and closes the connection. A failed metadata read, identity
transition, parked machine or pending enrollment returns an error object.
The client verifies root `SO_PEERCRED`, bounds the entire read to five seconds
and the reply to 2 KiB, and fails immediately on a full connect backlog.

A successful bind writes `/var/lib/cmux/install/identity.json`, a public receipt
of the machine, instance and install-key fingerprint, mode 0600. The query
requires that receipt, the installed key, `bound.json` and newly observed
provider instance all agree. Resuming the same instance keeps the key. A clone
cannot combine an inherited `bound.json` with a newly rotated install key.
Older guests without a receipt cannot use this new capability until a fresh
enrollment; their existing attach, status and chat paths are unchanged. Updating
acpmux alone is insufficient: the system host must support this query too.

This is a point-in-time observation, **not an authorization lease**. Callers must
query for every trigger operation and again after asynchronous verification,
compare the complete identity, and abort stale work. The host does not supervise
every on-demand acpmux process; this query does not stop inherited acpmux or make
an operation already executing during a memory snapshot atomic. A delivery
consumer must supply its own operation lifecycle fencing before claiming that
property. Guests with root compromise are outside this local identity boundary.
