// Prints a fresh private P-256 JWK (JSON) to stdout, for piping straight into
// `wrangler secret put SESSION_KEY|TICKET_KEY`. Never redirect it to a terminal.
if (process.stdout.isTTY) {
  console.error("refusing to print a private key to a terminal; pipe it into `wrangler secret put`");
  process.exit(1);
}
const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
process.stdout.write(JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d }));
