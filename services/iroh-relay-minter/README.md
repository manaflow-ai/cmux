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

## Relay-credential mirror (off by default)

`POST /api/relay-credentials` is a second home for the trust broker's
`relay.request.v1`, for when Cloudflare is down (RFD 0146,
`cloudflare-down-3h.md` step 5). Leo picked the stateless option on
2026-11-27 (TBD d-645f8cf975, "Trust the 1 h ticket, default-off").

The caller sends `Authorization: IrohTicket <ticket>`, the same 1 h v2 API ticket
the Worker accepts, and an empty body. The mirror checks the ticket's HMAC,
audience, environment, project, and its 1 h lifetime. It then signs the same
EdDSA relay JWT that `workers/iroh-v2/src/relay.ts` signs, for every configured
relay URL, and answers
`{"schemaId":"relay.result.v1","credentials":[{relayURL,token,expiresAt,refreshAfter}]}`.

The mirror cannot read the Worker's device store, so it does not see a
revocation. A device revoked during an outage keeps minting until its ticket
expires, which is at most 1 h later. To hold that bound, each credential expires
at the ticket's expiry or 30 minutes after issue, whichever comes first.
`/v2/tickets` keeps a single home, because a new ticket needs the Stack check
and the device record.

The mirror stays off, and the route answers 404 without reading any other
variable, unless `CMUX_RELAY_MIRROR_ENABLED=1`. Turning it on takes:

- `CMUX_RELAY_MIRROR_ENVIRONMENT` and `CMUX_RELAY_MIRROR_PROJECT_ID`, which are
  the Worker's `ENVIRONMENT` and `STACK_PROJECT_ID`.
- `CMUX_RELAY_MIRROR_TICKET_KEYS`, which is the Worker's `API_TICKET_KEYS`
  (JSON `{keyId: base64url}`).
- `CMUX_RELAY_MIRROR_RELAY_URLS`, which is the Worker's `RELAY_URLS` (JSON
  array).
- `CMUX_RELAY_MIRROR_RELAY_KEY_ID` and `CMUX_RELAY_MIRROR_RELAY_SIGNING_KEY`,
  which are the Worker's `RELAY_KEY_ID` and `RELAY_SIGNING_KEY` (an Ed25519
  PKCS#8 PEM).
