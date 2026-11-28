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
- `CMUX_IROH_MINT_HMAC_PREVIOUS_SECRET_B64`: optional minter-only previous key
  accepted during a bounded rotation overlap. It must differ from the current
  key. The web project never receives this value.

The web project requires the same `CMUX_IROH_MINT_HMAC_SECRET_B64` value and:

- `CMUX_IROH_MINT_URL=https://<minter-domain>/api/relay-token`

Rotate any Iroh Services credential previously pasted into chat or logs before
putting it in Vercel. A Services credential rotation affects only the minter.

Rotate the HMAC without an outage in this order:

1. Deploy the minter with the new key in `CMUX_IROH_MINT_HMAC_SECRET_B64` and
   the old key in `CMUX_IROH_MINT_HMAC_PREVIOUS_SECRET_B64`.
2. Change the web project's `CMUX_IROH_MINT_HMAC_SECRET_B64` to the new key.
3. Keep the previous key for at least five minutes, which covers the 30-second
   request timestamp window and deployment propagation.
4. Remove `CMUX_IROH_MINT_HMAC_PREVIOUS_SECRET_B64` from the minter.

The overlap changes only which HMAC key authenticates the existing fixed
method, path, timestamp, and body-hash transcript. It does not expand the
minter route or RCAN capabilities.

## Wire contract

The only accepted route is `POST /api/relay-token` with one `Content-Type`
header whose media type is `application/json`, optionally followed by parameters
such as `charset=utf-8`, no query string, and this body:

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

For authenticated local dogfood, the example server binds only to loopback and
uses the same request handler as the Vercel function:

```sh
CMUX_IROH_MINT_DEV_PORT=9460 cargo run --locked --example loopback
```

It still requires `IROH_SERVICES_API_SECRET` and
`CMUX_IROH_MINT_HMAC_SECRET_B64` in the process environment. Do not use a
credential copied through chat for a deployed environment; rotate it first.
