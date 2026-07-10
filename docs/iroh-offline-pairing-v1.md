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
variable. During signing-key rotation, publish the new current public key and
retain the old key as `previous` for at least seven days, the maximum pair-grant
lifetime. A forced account-subject-secret rotation invalidates cached offline
attestations, so clients must refresh before pairing.

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
compare account membership without disclosing the underlying identifier.

## Offline authorization

The Mac QR payload carries the Mac attestation. The iOS initiator also presents
its own cached attestation after the Iroh connection is established. Each peer
must perform all of these checks before accepting pairing:

1. Verify canonical JWS encoding and Ed25519 signature with a cached current or
   previous public key.
2. Require the fixed version, type, ALPN, scope, and a currently valid lifetime.
3. Bind every device, binding, EndpointID, identity generation, and platform
   claim to the expected local state and the authenticated Iroh peer EndpointID.
4. Require an iOS initiator, a Mac acceptor, distinct bindings, devices, and
   EndpointIDs, and equal 32-byte account subjects.
5. Apply local revocation and pairing-disabled state before accepting.

A missing attestation, one attestation used for both peers, a subject mismatch,
an expired token, or an EndpointID substitution fails closed. Network addresses
inside a QR remain untrusted route hints and do not participate in authorization.

Offline verification cannot observe a revocation made after the last refresh.
The 24-hour expiry bounds that window. A client without a fresh attestation must
go online before first-time pairing.

## Release gate

The TypeScript reference verifier and backend behavior tests enforce this
contract. Shipping offline QR pairing remains blocked until the Swift client has
equivalent behavior tests that prove QR possession alone fails, both
attestations are required, the live Iroh EndpointIDs are bound, and current plus
previous key rotation works.
