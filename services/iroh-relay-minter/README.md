# Iroh relay-token minter

This Vercel Rust project is the only cmux service allowed to hold the Iroh
Services project credential. It converts a short-lived request authenticated by
the cmux web trust broker into a 24-hour, endpoint-scoped RCAN containing only
`relay:use`.

Deploy this directory as a separate Vercel project. Set its Root Directory to
`services/iroh-relay-minter`. Do not add `IROH_SERVICES_API_SECRET` to the cmux
web project because Vercel environment variables are project-wide.

## Environment

The minter project requires:

- `IROH_SERVICES_API_SECRET`: the rotated Iroh Services project secret. It is
  parsed by `iroh-services` 1.0.0 and is never returned or logged.
- `CMUX_IROH_MINT_HMAC_SECRET_B64`: 32 to 256 random bytes encoded as canonical
  standard base64. Generate a new 32-byte value with `openssl rand -base64 32`.

The web project requires the same `CMUX_IROH_MINT_HMAC_SECRET_B64` value and:

- `CMUX_IROH_MINT_URL=https://<minter-domain>/api/relay-token`

Rotate any Iroh Services credential previously pasted into chat or logs before
putting it in Vercel. A Services credential rotation affects only the minter.
An HMAC rotation must update both projects together.

## Wire contract

The only accepted route is `POST /api/relay-token` with exact
`Content-Type: application/json`, no query string, and this body:

```json
{"endpointId":"<64 lowercase hex characters>","lifetimeSeconds":86400}
```

The web service sends:

- `x-cmux-iroh-timestamp`: canonical Unix seconds, within 30 seconds of the
  minter clock.
- `x-cmux-iroh-signature`: unpadded base64url HMAC-SHA256 over the transcript
  below.

```text
POST
/api/relay-token
<timestamp>
<lowercase SHA-256 hex of the exact body bytes>
```

The response is bounded JSON:

```json
{"token":"<lowercase unpadded base32 RCAN>","expiresAt":"<RFC 3339>"}
```

The RCAN issuer is the Iroh Services project key, the audience is the supplied
EndpointID, the sole capability is `relay:use`, and expiry is 86,400 seconds.
The trust broker stores only issuance audit state and refreshes the relay token
after 12 hours.

## Local verification

No production secrets are needed for tests.

```sh
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```
