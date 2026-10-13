// End-to-end test against the deployed cmux-next-native Worker.
// Usage: node test/e2e.mjs
// Env: BASE_URL (default https://cmux-next-native.debussy.workers.dev)
//      DEV_LOGIN_SECRET (default: read from ~/.secrets/cmux-next-native-dev-login)
// Requires Node 22+ (global fetch and WebSocket).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

const BASE = (process.env.BASE_URL ?? "https://cmux-next-native.debussy.workers.dev").replace(/\/$/, "");
const DEV_SECRET =
  process.env.DEV_LOGIN_SECRET ?? readFileSync(`${homedir()}/.secrets/cmux-next-native-dev-login`, "utf8").trim();
const WS_BASE = BASE.replace(/^http/, "ws");
const run = randomUUID().slice(0, 8);

let passed = 0;
async function step(name, fn) {
  try {
    const r = await fn();
    passed++;
    console.log(`ok   ${name}`);
    return r;
  } catch (e) {
    console.error(`FAIL ${name}\n     ${e?.stack ?? e}`);
    process.exit(1);
  }
}

async function api(method, path, { token, body } = {}) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  const r = await fetch(BASE + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  return { status: r.status, json };
}

// WebSocket helper with a message queue and predicate waits.
function openSocket(hostId, token) {
  const ws = new WebSocket(`${WS_BASE}/v1/signal/${hostId}?token=${encodeURIComponent(token)}`);
  const queue = [];
  const waiters = [];
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(ev.data);
    const i = waiters.findIndex((w) => w.pred(msg));
    if (i >= 0) waiters.splice(i, 1)[0].resolve(msg);
    else queue.push(msg);
  });
  const opened = new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket error")), { once: true });
  });
  return {
    ws,
    opened,
    send: (m) => ws.send(typeof m === "string" ? m : JSON.stringify(m)),
    next(pred = () => true, ms = 10000) {
      const i = queue.findIndex(pred);
      if (i >= 0) return Promise.resolve(queue.splice(i, 1)[0]);
      return new Promise((resolve, reject) => {
        const w = { pred, resolve };
        waiters.push(w);
        setTimeout(() => {
          const j = waiters.indexOf(w);
          if (j >= 0) {
            waiters.splice(j, 1);
            reject(new Error(`timeout waiting for message; queued=${JSON.stringify(queue)}`));
          }
        }, ms);
      });
    },
    close: () => ws.close(),
  };
}

function expectRejected(hostId, token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}/v1/signal/${hostId}?token=${encodeURIComponent(token)}`);
    ws.addEventListener("open", () => {
      ws.close();
      reject(new Error("socket unexpectedly opened"));
    });
    ws.addEventListener("error", () => resolve());
  });
}

console.log(`cmux-next-native e2e against ${BASE} (run ${run})`);

await step("GET /healthz", async () => {
  const r = await api("GET", "/healthz");
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
});

const login = await step("POST /v1/auth/dev", async () => {
  const r = await api("POST", "/v1/auth/dev", { body: { email: `e2e-${run}@test.cmux.dev`, secret: DEV_SECRET } });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.ok(r.json.session_token);
  assert.ok(r.json.user.id);
  return r.json;
});
const token = login.session_token;

await step("dev login rejects bad secret and non-test email", async () => {
  const bad = await api("POST", "/v1/auth/dev", { body: { email: `x-${run}@test.cmux.dev`, secret: "nope" } });
  assert.equal(bad.status, 403);
  const other = await api("POST", "/v1/auth/dev", { body: { email: `x-${run}@example.com`, secret: DEV_SECRET } });
  assert.equal(other.status, 403);
});

await step("POST /v1/auth/apple rejects garbage token", async () => {
  const r = await api("POST", "/v1/auth/apple", { body: { identity_token: "a.b.c" } });
  assert.equal(r.status, 401);
});

await step("GET /v1/me", async () => {
  const r = await api("GET", "/v1/me", { token });
  assert.equal(r.status, 200);
  assert.equal(r.json.user.id, login.user.id);
  assert.equal((await api("GET", "/v1/me")).status, 401);
});

const reg = await step("POST /v1/hosts/register", async () => {
  const r = await api("POST", "/v1/hosts/register", { body: { name: `e2e-host-${run}`, platform: "macos" } });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  assert.match(r.json.host_id, /^[0-9a-f]{32}$/);
  assert.ok(r.json.host_secret);
  assert.match(r.json.pairing_code, /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/);
  return r.json;
});
const hostId = reg.host_id;
const hostSecret = reg.host_secret;

const code = await step("POST /v1/hosts/pairing-code (host auth) replaces old code", async () => {
  const r = await api("POST", "/v1/hosts/pairing-code", { token: hostSecret });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.match(r.json.pairing_code, /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/);
  assert.notEqual(r.json.pairing_code, reg.pairing_code);
  const stale = await api("POST", "/v1/pair", { token, body: { code: reg.pairing_code } });
  assert.equal(stale.status, 404, "old code must be invalid after a new one is issued");
  return r.json.pairing_code;
});

await step("phone cannot signal an unpaired host", async () => {
  await expectRejected(hostId, token);
});

await step("POST /v1/pair", async () => {
  const r = await api("POST", "/v1/pair", { token, body: { code: code.toLowerCase().replace("-", "") } });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.host.id, hostId);
  const again = await api("POST", "/v1/pair", { token, body: { code } });
  assert.equal(again.status, 404, "pairing code must be single use");
});

await step("GET /v1/hosts (offline)", async () => {
  const r = await api("GET", "/v1/hosts", { token });
  assert.equal(r.status, 200);
  const h = r.json.hosts.find((x) => x.id === hostId);
  assert.ok(h, "paired host listed");
  assert.equal(h.online, false);
});

await step("GET /v1/ice (user and host auth)", async () => {
  for (const t of [token, hostSecret]) {
    const r = await api("GET", "/v1/ice", { token: t });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    const urls = r.json.iceServers.flatMap((s) => [s.urls].flat());
    assert.ok(urls.some((u) => u.startsWith("turn:") || u.startsWith("turns:")), `turn url in ${urls}`);
    assert.ok(urls.includes("stun:stun.cloudflare.com:3478"));
    assert.ok(r.json.iceServers.some((s) => s.username && s.credential));
  }
  assert.equal((await api("GET", "/v1/ice")).status, 401);
});

const sid = randomUUID();

await step("phone gets host_offline when host is not connected", async () => {
  const phone = openSocket(hostId, token);
  await phone.opened;
  const pres = await phone.next((m) => m.t === "presence");
  assert.equal(pres.online, false);
  phone.send({ t: "offer", sid, sdp: "v=0 offer" });
  const err = await phone.next((m) => m.t === "error");
  assert.equal(err.code, "host_offline");
  phone.close();
});

await step("signaling round trip offer/answer/ice", async () => {
  const host = openSocket(hostId, hostSecret);
  await host.opened;
  const phone = openSocket(hostId, token);
  await phone.opened;
  assert.equal((await phone.next((m) => m.t === "presence")).online, true);

  // keepalive auto-response
  phone.send({ t: "ping" });
  await phone.next((m) => m.t === "pong");

  phone.send({ t: "offer", sid, sdp: "v=0 offer-sdp", from: "spoofed" });
  const offer = await host.next((m) => m.t === "offer");
  assert.equal(offer.sid, sid);
  assert.equal(offer.sdp, "v=0 offer-sdp");
  assert.equal(offer.from, "phone");
  assert.equal(offer.user_id, login.user.id);

  host.send({ t: "answer", sid, sdp: "v=0 answer-sdp" });
  const answer = await phone.next((m) => m.t === "answer");
  assert.equal(answer.sdp, "v=0 answer-sdp");
  assert.equal(answer.from, "host");

  const cand = { candidate: "candidate:1 1 udp 2122260223 192.0.2.1 54400 typ host", sdpMid: "0", sdpMLineIndex: 0 };
  phone.send({ t: "ice", sid, candidate: cand });
  const ice1 = await host.next((m) => m.t === "ice");
  assert.deepEqual(ice1.candidate, cand);
  host.send({ t: "ice", sid, candidate: cand });
  const ice2 = await phone.next((m) => m.t === "ice");
  assert.deepEqual(ice2.candidate, cand);

  host.send({ t: "answer", sid: randomUUID(), sdp: "x" });
  assert.equal((await host.next((m) => m.t === "error")).code, "unknown_sid");

  const list = await api("GET", "/v1/hosts", { token });
  const h = list.json.hosts.find((x) => x.id === hostId);
  assert.equal(h.online, true, "host reported online while connected");
  assert.ok(h.last_seen > 0);

  phone.send({ t: "bye", sid });
  assert.equal((await host.next((m) => m.t === "bye")).sid, sid);

  // Host disconnect is pushed to phones and reflected in presence.
  host.close();
  assert.equal((await phone.next((m) => m.t === "presence" && m.online === false)).online, false);
  const after = await api("GET", "/v1/hosts", { token });
  const ha = after.json.hosts.find((x) => x.id === hostId);
  assert.equal(ha.online, false, "host offline after disconnect");
  assert.ok(ha.last_seen > 0, "last_seen recorded");
  phone.close();
});

await step("another user cannot signal or unpair the host", async () => {
  const other = await api("POST", "/v1/auth/dev", { body: { email: `e2e-other-${run}@test.cmux.dev`, secret: DEV_SECRET } });
  await expectRejected(hostId, other.json.session_token);
  const del = await api("DELETE", `/v1/hosts/${hostId}`, { token: other.json.session_token });
  assert.equal(del.status, 404);
});

await step("DELETE /v1/hosts/:id unpairs", async () => {
  const r = await api("DELETE", `/v1/hosts/${hostId}`, { token });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const list = await api("GET", "/v1/hosts", { token });
  assert.ok(!list.json.hosts.some((x) => x.id === hostId));
  await expectRejected(hostId, token);
});

await step("POST /v1/auth/logout revokes the session and its push device", async () => {
  const fresh = await api("POST", "/v1/auth/dev", { body: { email: `e2e-${run}@test.cmux.dev`, secret: DEV_SECRET } });
  const t = fresh.json.session_token;
  const apns = "ab".repeat(32);
  const reg = await api("POST", "/v1/push/register", { token: t, body: { apns_token: apns, environment: "sandbox" } });
  assert.equal(reg.status, 200, JSON.stringify(reg.json));
  const out = await api("POST", "/v1/auth/logout", { token: t, body: { apns_token: apns } });
  assert.equal(out.status, 200, JSON.stringify(out.json));
  const me = await api("GET", "/v1/me", { token: t });
  assert.equal(me.status, 401);
});

console.log(`\nall ${passed} steps passed`);
process.exit(0);
