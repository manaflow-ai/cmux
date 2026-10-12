// Unit tests for APNs JWT signing and payload building.
// Run: npm test  (node --test with TypeScript type stripping, Node 22.18+)
import assert from "node:assert/strict";
import { generateKeyPairSync, webcrypto } from "node:crypto";
import { test } from "node:test";
import {
  apnsHeaders,
  buildAlertPayload,
  buildLiveActivityStartPayload,
  buildLiveActivityUpdatePayload,
  categoryFor,
  isDeadToken,
  parseAttentionEvent,
  pemToDer,
  signApnsJwt,
  threadId,
} from "../src/apns.ts";

function b64urlDecode(s) {
  return Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const p8 = privateKey.export({ type: "pkcs8", format: "pem" });

const event = (over = {}) => ({
  id: "n-42",
  kind: "question",
  title: "Claude needs your input",
  body: "Do you want to make this edit to index.ts?",
  surface: 7,
  workspace: "cmux",
  agent: "claude",
  options: [
    { key: "1", label: "Yes" },
    { key: "2", label: "Yes, and don't ask again" },
    { key: "3", label: "No, and tell Claude what to do differently" },
  ],
  quote: "refactor the signal router",
  created_at: 1760000000000,
  ...over,
});

test("signApnsJwt produces an ES256 JWT that verifies with the key's public half", async () => {
  const jwt = await signApnsJwt({ p8, keyId: "ABC123DEFG", teamId: "7WLXT3NR37" }, 1760000000);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(b64urlDecode(h)), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(b64urlDecode(c)), { iss: "7WLXT3NR37", iat: 1760000000 });
  const sig = b64urlDecode(s);
  assert.equal(sig.length, 64, "raw r||s, not DER");
  const pub = await webcrypto.subtle.importKey(
    "spki",
    publicKey.export({ type: "spki", format: "der" }),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const ok = await webcrypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
});

test("pemToDer accepts a secret pasted with literal \\n escapes", () => {
  const escaped = p8.replace(/\n/g, "\\n");
  assert.deepEqual(pemToDer(escaped), pemToDer(p8));
});

test("alert payload: category, thread, mutable content, cmux block", () => {
  const p = buildAlertPayload({ hostId: "h1", hostName: "Mac", event: event() });
  assert.equal(p.aps.category, "FEED_QUESTION");
  assert.equal(p.aps["thread-id"], "host-h1-surface-7");
  assert.equal(p.aps["mutable-content"], 1);
  assert.equal(p.aps.alert.title, "Claude needs your input");
  assert.equal(p.aps.alert.subtitle, "Claude · cmux");
  assert.equal(p.aps["interruption-level"], "time-sensitive");
  assert.equal(p.cmux.event_id, "n-42");
  assert.equal(p.cmux.surface, 7);
  assert.equal(p.cmux.options.length, 3);
  assert.equal(p.cmux.quote, "refactor the signal router");
});

test("categories per kind", () => {
  assert.equal(categoryFor({ kind: "permission" }), "FEED_PERMISSION");
  assert.equal(categoryFor({ kind: "done" }), "FEED_DONE");
  assert.equal(categoryFor({ kind: "error" }), "FEED_GENERIC");
  assert.equal(categoryFor({ kind: "notice" }), "FEED_GENERIC");
  assert.equal(threadId("h1", null), "host-h1");
});

test("empty title and body get defaults", () => {
  const p = buildAlertPayload({ hostId: "h1", event: event({ kind: "done", title: "", body: "", agent: "codex" }) });
  assert.equal(p.aps.alert.title, "Codex finished");
  assert.equal(p.aps.alert.body, "In cmux");
  assert.equal(p.aps["interruption-level"], "active");
});

test("payload stays under 4 KB", () => {
  const big = "x".repeat(10000);
  const p = buildAlertPayload({ hostId: "h1", event: event({ body: big, quote: big, title: big }) });
  assert.ok(Buffer.byteLength(JSON.stringify(p)) <= 4096);
});

test("live activity start and update payloads", () => {
  const attrs = { hostID: "h1", surface: 7, agent: "Claude", workspace: "cmux" };
  const content = { state: "working", startedAt: 1760000000, detail: "Working" };
  const start = buildLiveActivityStartPayload(attrs, content, 1760000100);
  assert.equal(start.aps.event, "start");
  assert.equal(start.aps["attributes-type"], "AgentActivityAttributes");
  assert.deepEqual(start.aps.attributes, attrs);
  assert.deepEqual(start.aps["content-state"], content);
  assert.equal(start.aps.timestamp, 1760000100);
  const end = buildLiveActivityUpdatePayload({ ...content, state: "done" }, 1760000200, { end: true });
  assert.equal(end.aps.event, "end");
  assert.equal(end.aps["dismissal-date"], 1760000200 + 900);
  const upd = buildLiveActivityUpdatePayload(content, 1760000200);
  assert.equal(upd.aps.event, "update");
  assert.ok(!("dismissal-date" in upd.aps));
});

test("apns headers", () => {
  const h = apnsHeaders(
    { token: "ab", environment: "sandbox", topic: "dev.cmux.next.native.dev.push-type.liveactivity", pushType: "liveactivity", payload: {}, collapseId: "c" },
    "JWT",
  );
  assert.equal(h.authorization, "bearer JWT");
  assert.equal(h["apns-push-type"], "liveactivity");
  assert.equal(h["apns-topic"], "dev.cmux.next.native.dev.push-type.liveactivity");
  assert.equal(h["apns-collapse-id"], "c");
});

test("dead token detection", () => {
  assert.ok(isDeadToken({ ok: false, status: 410 }));
  assert.ok(isDeadToken({ ok: false, status: 400, reason: "BadDeviceToken" }));
  assert.ok(!isDeadToken({ ok: false, status: 403, reason: "InvalidProviderToken" }));
});

test("parseAttentionEvent validates and clips", () => {
  const e = parseAttentionEvent({ id: "x", kind: "permission", title: "t", surface: 3, options: [{ key: "1", label: "Allow" }, { nope: 1 }] });
  assert.equal(e.kind, "permission");
  assert.equal(e.options.length, 1);
  assert.equal(e.workspace, null);
  assert.throws(() => parseAttentionEvent({ id: "x", kind: "bogus" }));
  assert.throws(() => parseAttentionEvent({ id: "x", kind: "done", surface: 1.5 }));
});
