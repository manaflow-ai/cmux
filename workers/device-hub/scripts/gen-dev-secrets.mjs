// Writes .dev.vars with fresh SESSION_KEY and TICKET_KEY (P-256 private JWKs).
// Never prints the values. Usage: node scripts/gen-dev-secrets.mjs [path]
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const path = process.argv[2] ?? ".dev.vars";
const gen = async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return JSON.stringify({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d });
};
const keep = existsSync(path)
  ? readFileSync(path, "utf8").split("\n").filter((l) => l && !/^(SESSION_KEY|TICKET_KEY)=/.test(l))
  : [];
const lines = [...keep, `SESSION_KEY='${await gen()}'`, `TICKET_KEY='${await gen()}'`];
writeFileSync(path, lines.join("\n") + "\n", { mode: 0o600 });
console.log(`wrote ${path} (SESSION_KEY, TICKET_KEY)`);
