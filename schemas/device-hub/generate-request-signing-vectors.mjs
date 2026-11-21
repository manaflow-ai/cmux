// Writes request-signing-vectors.json beside this file: the device-signed request
// contract of docs/device-hub/PROTOCOL.md ("Device-signed requests"), checked by the
// hub (workers/device-hub), the screen host (cmux-hub-host hub.rs) and the
// apps (Packages/Shared/CmuxDeviceHub). Run: node schemas/device-hub/generate-request-signing-vectors.mjs
// ECDSA signatures are random, so a rerun rewrites every signature; the canonical
// strings and verdicts stay the same.
import { createHash, webcrypto } from "node:crypto";
import { writeFileSync } from "node:fs";

const { subtle } = webcrypto;
const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
const b64 = (bytes) => Buffer.from(bytes).toString("base64");
const hex = (bytes) => Buffer.from(bytes).toString("hex");
const sha256 = (s) => createHash("sha256").update(Buffer.from(s, "utf8")).digest("hex");

function canonical(method, pathAndQuery, ts, body) {
  const hash = body === null || body.length === 0 ? "" : sha256(body);
  return `${method.toUpperCase()}\n${pathAndQuery}\n${ts}\n${hash}`;
}

const canonicalCases = [
  ["get without a body", "GET", "/v1/user/ws", 1700000000, null],
  ["post with a JSON body", "POST", "/v1/devices", 7, "{}"],
  ["method is upper-cased", "put", "/v1/permissions/h/v", 1800000000, '{"scope":"view"}'],
  ["an empty body hashes to the empty line", "DELETE", "/v1/relays/r", 7, ""],
  ["path and query are signed as sent", "GET", "/v1/sessions/s%201/ws?ticket=a.b.c", 1800000000, null],
  ["body hash is over UTF-8 bytes", "PUT", "/v1/devices/x", 1800000000, '{"name":"Mac été"}'],
].map(([name, method, pathAndQuery, ts, body]) => ({
  name,
  method,
  pathAndQuery,
  ts,
  body,
  canonical: canonical(method, pathAndQuery, ts, body),
}));

const pair = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const publicKey = b64(new Uint8Array(await subtle.exportKey("raw", pair.publicKey)));
const message = canonicalCases[1].canonical;
const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, Buffer.from(message)));
const r = raw.slice(0, 32);
const s = BigInt("0x" + hex(raw.slice(32)));
const low = s > N / 2n ? N - s : s;
const high = N - low;
const as32 = (n) => Buffer.from(n.toString(16).padStart(64, "0"), "hex");
const lowSig = Buffer.concat([r, as32(low)]);
const highSig = Buffer.concat([r, as32(high)]);
const lowSHex = hex(r) + low.toString(16).padStart(64, "0");

const signatures = {
  publicKey,
  cases: [
    { name: "low-S signature verifies", message, signature: b64(lowSig), verifies: true, lowSHex },
    { name: "high-S copy verifies and has the same replay key", message, signature: b64(highSig), verifies: true, lowSHex },
    { name: "another message does not verify", message: canonicalCases[0].canonical, signature: b64(lowSig), verifies: false, lowSHex },
    { name: "a 63-byte signature is refused", message, signature: b64(lowSig.subarray(0, 63)), verifies: false, lowSHex: null },
  ],
};

const out = new URL("./request-signing-vectors.json", import.meta.url);
writeFileSync(out, JSON.stringify({ protocol: "device-hub/1 device-signed requests", canonical: canonicalCases, signatures }, null, 2) + "\n");
