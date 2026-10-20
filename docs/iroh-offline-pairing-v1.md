# Iroh offline same-account pairing v1

Offline QR pairing is authorized by two backend-signed endpoint attestations.
Possession of the QR payload is never sufficient.

## Online preparation

Authenticated clients fetch `GET /api/devices/iroh`. Its
`grant_verification_keys` field is a version 1 public Ed25519 key set containing
the current key and, during rotation, one previous key. The response never
contains a private key, account ID, email, or team ID.

An authenticated client requests an attestation for its active binding with:

```http
POST /api/devices/iroh/endpoint-attestations
Content-Type: application/json

{"bindingId":"<binding UUID>"}
```

The response contains `attestation_version`, `attestation`, `expires_at`, and
the same public verification-key set. The attestation lifetime is 24 hours.
Revoked bindings and bindings owned by another account return `binding_not_found`.

The web deployment requires these server-only values:

- `CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64`: 32 random bytes in standard base64.
- `CMUX_IROH_GRANT_SIGNING_KEY_P8`: an Ed25519 PKCS#8 private key in PEM form.
- `CMUX_IROH_GRANT_SIGNING_KID`: the current key ID.
- `CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON`: the version 1 current plus optional
  previous public-key set shown by the API.

Generate signing material with:

```sh
openssl genpkey -algorithm ED25519 -out iroh-grant-current.pem
openssl pkey -in iroh-grant-current.pem -pubout -outform DER | openssl base64 -A
openssl rand -base64 32
```

Never put the private key or account-subject secret in a client-visible Vercel
variable. Rotate signing keys in three deployments:

1. Keep the old signer and `current_kid`, then add the next public key as the
   second verification key.
2. After clients have fetched that key set, switch the signer and `current_kid`
   to the new key while retaining the old public key as the second key.
3. At least seven days after the signer switch, remove the old public key. Seven
   days is the maximum online pair-grant lifetime.

The service rejects a deployment whose private signer does not match
`current_kid`. Roll back signer, KID, and verification-key JSON as one unit. A
forced account-subject-secret rotation invalidates cached offline attestations,
so clients must refresh before pairing.

## Signed attestation

The attestation is a compact JWS signed with Ed25519. The protected header has
exactly these fields:

```json
{"alg":"EdDSA","typ":"cmux-endpoint-attestation-v1+jwt","kid":"<current key ID>"}
```

The payload has exactly these fields:

```json
{
  "version": 1,
  "jti": "<UUID>",
  "sub": "<32-byte unpadded base64url account subject>",
  "bindingId": "<UUID>",
  "deviceId": "<UUID>",
  "endpointId": "<64 lowercase hex characters>",
  "identityGeneration": 1,
  "platform": "ios",
  "iat": 1783627200,
  "nbf": 1783627195,
  "exp": 1783713600,
  "alpn": "cmux/mobile/1",
  "scope": "cmux.offline-pair.same-account"
}
```

`sub` is HMAC-SHA256 over the private backend account identifier with a
dedicated server secret and a versioned domain separator. It lets two devices
compare account membership without disclosing the underlying identifier. It is
stable for that account until the subject secret rotates. A peer that collects
copied attestations can therefore correlate them as belonging to the same
account during their 24-hour validity. Session-scoping `sub` would require both
devices to contact the backend for the same session, which would remove the
offline property. The one-use local invitation below limits authorization
replay, but does not remove this pseudonymous correlation. The final privacy
review must re-evaluate this tradeoff before release.

## Offline authorization

The Mac creates a five-minute local pairing session inside its endpoint actor.
It generates a random UUID `session_id` and 32 random bytes `proof`. The QR
contains this exact authorization object plus the Mac attestation:

```json
{
  "version": 1,
  "session_id": "<UUID>",
  "proof": "<32-byte unpadded base64url>",
  "expires_at": 1783627500,
  "acceptor_attestation": "<compact JWS>"
}
```

The Mac stores only the proof hash, exact local binding/device/EndpointID/
identity-generation tuple, expiry, and an unconsumed marker. Route hints may be
included elsewhere in the QR, but never enter the proof transcript. The iOS
initiator presents the QR authorization and its own cached attestation after
the authenticated Iroh connection is established. The Mac performs all checks
and the consume transition in one actor-isolated operation:

1. Verify canonical JWS encoding and Ed25519 signature with a cached current or
   previous public key.
2. Require the fixed version, type, ALPN, scope, and a currently valid lifetime.
3. Bind every device, binding, EndpointID, identity generation, and platform
   claim to the expected local state and the authenticated Iroh peer EndpointID.
4. Require an iOS initiator, a Mac acceptor, distinct bindings, devices, and
   EndpointIDs, and equal 32-byte account subjects.
5. Require the signed online pair-grant direction everywhere: iOS initiator and
   Mac acceptor.
6. Require the exact unexpired local `session_id`, constant-time proof-hash
   match, exact local acceptor tuple, and `consumed_at == nil`.
7. Apply local revocation and pairing-disabled state, then set `consumed_at`
   before returning the accepted admission.

A missing attestation, one attestation used for both peers, a subject mismatch,
an expired token, an EndpointID substitution, a wrong proof, or a replayed
session fails closed. A failed proof or attestation check does not consume the
session. A successful session is consumed even if later application setup
fails, so retry requires a new QR. Network addresses inside a QR remain
untrusted route hints and do not participate in authorization.

Offline verification cannot observe a revocation made after the last refresh.
The 24-hour expiry bounds that window. A client without a fresh attestation must
go online before first-time pairing.

## Release gate

The TypeScript reference verifier and backend behavior tests enforce this
contract, including one-use consumption and staged key rotation. Shipping
offline QR pairing remains blocked until the Swift client has equivalent actor
tests that prove QR possession alone fails, both attestations are required, the
live Iroh EndpointIDs are bound, concurrent replay has one winner, and current
plus previous key rotation works. Release also requires a privacy decision on
the documented 24-hour pseudonymous account-correlation window. Production and
staging must use distinct account-subject secrets and Ed25519 signing key sets,
so an attestation from one environment cannot verify in another.
