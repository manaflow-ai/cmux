#!/usr/bin/env node
// Mints a fresh CLOUD_LINK_SIGNING_KEYS value: {"active":"<kid>","keys":{"<kid>":<Ed25519 private JWK>}}, the shape
// backend/apps/api/src/link-token.ts parseSigningKeys (and cmux-platform's LinkToken.ts) accepts. One kid and no
// published_at, so it signs at once (signingKid). The value goes to stdout only, for a pipe straight into
// `wrangler secret put`; nothing is logged or written to disk. Usage: node mint-link-keyset.mjs [kid-prefix]
// (default "production"; the kid is "<prefix>-<YYYY-MM-DD>", UTC).
import { generateKeyPairSync } from "node:crypto"

const KID = /^[A-Za-z0-9._-]{1,64}$/
const prefix = process.argv[2] ?? "production"
const kid = `${prefix}-${new Date().toISOString().slice(0, 10)}`
if (!KID.test(kid)) {
  process.stderr.write(`mint-link-keyset: invalid kid prefix (must make a kid matching ${KID})\n`)
  process.exit(2)
}
const { privateKey } = generateKeyPairSync("ed25519")
const jwk = privateKey.export({ format: "jwk" })
if (jwk.kty !== "OKP" || jwk.crv !== "Ed25519" || typeof jwk.x !== "string" || typeof jwk.d !== "string" || !jwk.x || !jwk.d) {
  process.stderr.write("mint-link-keyset: node:crypto returned an unexpected JWK shape\n")
  process.exit(1)
}
process.stdout.write(JSON.stringify({ active: kid, keys: { [kid]: { kty: "OKP", crv: "Ed25519", x: jwk.x, d: jwk.d, kid } } }))
