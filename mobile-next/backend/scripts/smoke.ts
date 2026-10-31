// End-to-end smoke test against a deployed Worker.
// Usage: bun scripts/smoke.ts [base_url]
// Reads the test login code from ~/.secrets/cmux-next-mobile-native-test-login.
// Signs in as smoke-native@<test domain>, which must be listed in the Worker's
// TEST_LOGIN_EMAILS, and deletes that account at the end.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BASE = (process.argv[2] ?? process.env.SMOKE_BASE_URL ?? "https://cmux-next-mobile-native.debussy.workers.dev").replace(/\/$/, "");
const secrets = Object.fromEntries(
  readFileSync(join(homedir(), ".secrets/cmux-next-mobile-native-test-login"), "utf8")
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
) as { EMAIL_DOMAIN: string; CODE: string };

let passed = 0;
const results: string[] = [];
function check(name: string, cond: unknown, detail?: unknown): void {
  if (!cond) {
    console.error(`FAIL ${name}`, detail === undefined ? "" : JSON.stringify(detail));
    process.exit(1);
  }
  passed++;
  results.push(name);
  console.log(`ok   ${name}`);
}

async function api<T = any>(method: string, path: string, opts: { token?: string; body?: unknown } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}),
      ...(opts.body !== undefined ? { "content-type": "application/json" } : {}),
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: res.status, body: body as T };
}

// ---------- WebSocket helper
class Peer {
  ws!: WebSocket;
  inbox: any[] = [];
  waiters: Array<{ pred: (m: any) => boolean; resolve: (m: any) => void }> = [];
  constructor(readonly id: string) {}
  /** Opens with an Authorization header, or with the legacy `?token=` query when `legacyQuery` is set. */
  open(token: string, legacyQuery = false): Promise<any> {
    const base = `${BASE.replace(/^http/, "ws")}/v1/signal?peer=${this.id}`;
    this.ws = legacyQuery
      ? new WebSocket(`${base}&token=${encodeURIComponent(token)}`)
      : new WebSocket(base, { headers: { authorization: `Bearer ${token}` } } as any);
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(String(ev.data));
      const i = this.waiters.findIndex((w) => w.pred(msg));
      if (i >= 0) this.waiters.splice(i, 1)[0]!.resolve(msg);
      else this.inbox.push(msg);
    };
    return this.next((m) => m.type === "welcome");
  }
  send(msg: unknown) {
    this.ws.send(typeof msg === "string" ? msg : JSON.stringify(msg));
  }
  next(pred: (m: any) => boolean, timeoutMs = 10000): Promise<any> {
    const i = this.inbox.findIndex(pred);
    if (i >= 0) return Promise.resolve(this.inbox.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve: (m: any) => (clearTimeout(t), resolve(m)) };
      const t = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        reject(new Error(`${this.id}: timed out waiting for message`));
      }, timeoutMs);
      this.waiters.push(w);
    });
  }
  close() {
    this.ws.close(1000, "done");
  }
}

/** Status of a WebSocket upgrade attempt that is expected to be refused. */
async function upgradeStatus(query: string, token: string): Promise<number> {
  const res = await fetch(`${BASE}/v1/signal?${query}`, {
    headers: { upgrade: "websocket", connection: "Upgrade", "sec-websocket-version": "13", "sec-websocket-key": btoa("smoke-smoke-smo!"), authorization: `Bearer ${token}` },
  });
  await res.body?.cancel();
  return res.status;
}

// ---------- run
console.log(`smoke: ${BASE}`);
const email = `smoke-native@${secrets.EMAIL_DOMAIN}`;

check("GET /healthz", (await api("GET", "/healthz")).body.ok === true);

const start = await api("POST", "/v1/auth/email/start", { body: { email } });
check("POST /v1/auth/email/start (test address)", start.status === 200 && start.body.sent === true, start);

const notListed = await api("POST", "/v1/auth/email/start", { body: { email: `not-listed-${Date.now().toString(36)}@${secrets.EMAIL_DOMAIN}` } });
check(
  "POST /v1/auth/email/start (test domain, not in TEST_LOGIN_EMAILS) is 503 email_unavailable",
  notListed.status === 503 && notListed.body.error?.code === "email_unavailable",
  notListed,
);

const nonTest = await api("POST", "/v1/auth/email/start", { body: { email: "someone@example.com" } });
check(
  "POST /v1/auth/email/start (non-test) is sent or 503 email_unavailable",
  nonTest.status === 200 || (nonTest.status === 503 && nonTest.body.error?.code === "email_unavailable"),
  nonTest,
);

const wrong = await api("POST", "/v1/auth/email/verify", { body: { email, code: secrets.CODE === "000000" ? "000001" : "000000" } });
check("POST /v1/auth/email/verify rejects a wrong code", wrong.status === 400 && wrong.body.error.code === "invalid_code", wrong);

const verify = await api("POST", "/v1/auth/email/verify", { body: { email, code: secrets.CODE } });
check("POST /v1/auth/email/verify", verify.status === 200 && verify.body.access_token && verify.body.user?.email === email, verify);
let session = verify.body;
const userId = session.user.id;

const reuse = await api("POST", "/v1/auth/email/verify", { body: { email, code: secrets.CODE } });
check("email code is single use", reuse.status === 400, reuse);

const me = await api("GET", "/v1/me", { token: session.access_token });
check("GET /v1/me", me.status === 200 && me.body.id === userId && me.body.email === email, me);
check("GET /v1/me without token is 401", (await api("GET", "/v1/me")).status === 401);

const patched = await api("PATCH", "/v1/me", { token: session.access_token, body: { display_name: "Smoke Test" } });
check("PATCH /v1/me", patched.status === 200 && patched.body.display_name === "Smoke Test", patched);

const refreshed = await api("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } });
check("POST /v1/auth/refresh", refreshed.status === 200 && refreshed.body.refresh_token !== session.refresh_token, refreshed);
const replay = await api("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } });
check("refresh token rotation rejects the old token", replay.status === 401, replay);
session = refreshed.body;
const family = await api("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } });
check("refresh token reuse revokes the newer refresh token too", family.status === 401, family);
const token = session.access_token as string;

// pairing (claim -> Mac approval -> token once)
const pstart = await api("POST", "/v1/pairing/start", { body: { host_name: "Smoke Mac", platform: "macos", app_version: "0.0.1" } });
check(
  "POST /v1/pairing/start (8-character code)",
  pstart.status === 200 && /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/.test(pstart.body.code) && pstart.body.poll_secret,
  pstart,
);
const pairingId = pstart.body.pairing_id as string;
const pollSecret = pstart.body.poll_secret as string;
const pollPath = `/v1/pairing/${pairingId}?poll_secret=${encodeURIComponent(pollSecret)}`;
const pending = await api("GET", pollPath);
check("GET /v1/pairing/:id pending", pending.status === 200 && pending.body.status === "pending", pending);
check("pairing poll rejects a wrong secret", (await api("GET", `/v1/pairing/${pairingId}?poll_secret=nope`)).status === 404);
const early = await api("POST", `/v1/pairing/${pairingId}/approve`, { body: { poll_secret: pollSecret } });
check("approve before a claim is 409 invalid_pairing_state", early.status === 409 && early.body.error.code === "invalid_pairing_state", early);

const dashed = `${pstart.body.code.slice(0, 4)}-${pstart.body.code.slice(4)}`.toLowerCase();
const claim = await api("POST", "/v1/pairing/claim", { token, body: { code: dashed } });
check(
  "POST /v1/pairing/claim -> awaiting_approval",
  claim.status === 200 && claim.body.status === "awaiting_approval" && claim.body.host?.name === "Smoke Mac",
  claim,
);
const hostId = claim.body.host.id;
const reclaim = await api("POST", "/v1/pairing/claim", { token, body: { code: pstart.body.code } });
check("an awaiting pairing cannot be claimed again", reclaim.status === 404, reclaim);

const awaiting = await api("GET", pollPath);
check(
  "GET /v1/pairing/:id awaiting_approval shows the user's email",
  awaiting.status === 200 && awaiting.body.status === "awaiting_approval" && awaiting.body.user?.email === email && awaiting.body.user?.id === userId,
  awaiting,
);
check(
  "host is not listed before approval",
  !(await api("GET", "/v1/hosts", { token })).body.hosts.some((h: any) => h.id === hostId),
);
check(
  "approve rejects a wrong poll secret",
  (await api("POST", `/v1/pairing/${pairingId}/approve`, { body: { poll_secret: "cnp_wrong" } })).status === 404,
);
const approve = await api("POST", `/v1/pairing/${pairingId}/approve`, { body: { poll_secret: pollSecret } });
check("POST /v1/pairing/:id/approve", approve.status === 200 && approve.body.status === "approved", approve);

const claimed = await api("GET", pollPath);
check(
  "GET /v1/pairing/:id claimed (token after approval)",
  claimed.status === 200 && claimed.body.status === "claimed" && claimed.body.host_id === hostId && claimed.body.host_token && claimed.body.user.id === userId,
  claimed,
);
const hostToken = claimed.body.host_token as string;
const consumed = await api("GET", pollPath);
check("pairing token is delivered once", consumed.status === 410 && consumed.body.error.code === "pairing_consumed", consumed);

// pairing (claim -> Mac rejects)
const rstart = await api("POST", "/v1/pairing/start", { body: { host_name: "Rejected Mac", platform: "macos", app_version: "0.0.1" } });
const rPoll = `/v1/pairing/${rstart.body.pairing_id}?poll_secret=${encodeURIComponent(rstart.body.poll_secret)}`;
const rclaim = await api("POST", "/v1/pairing/claim", { token, body: { code: rstart.body.code } });
check("claim for the rejection flow", rclaim.status === 200 && rclaim.body.status === "awaiting_approval", rclaim);
const reject = await api("POST", `/v1/pairing/${rstart.body.pairing_id}/reject`, { body: { poll_secret: rstart.body.poll_secret } });
check("POST /v1/pairing/:id/reject", reject.status === 200 && reject.body.status === "rejected", reject);
const rpolled = await api("GET", rPoll);
check("poll after reject is rejected", rpolled.status === 200 && rpolled.body.status === "rejected", rpolled);
check(
  "rejected host is never listed",
  !(await api("GET", "/v1/hosts", { token })).body.hosts.some((h: any) => h.id === rclaim.body.host.id),
);

const hostMe = await api("GET", "/v1/host/me", { token: hostToken });
check("GET /v1/host/me", hostMe.status === 200 && hostMe.body.host.id === hostId && hostMe.body.user.id === userId, hostMe);

let hosts = await api("GET", "/v1/hosts", { token });
check("GET /v1/hosts (offline)", hosts.status === 200 && hosts.body.hosts.some((h: any) => h.id === hostId && h.online === false), hosts);

const renamed = await api("PATCH", `/v1/hosts/${hostId}`, { token, body: { name: "Smoke Mac 2" } });
check("PATCH /v1/hosts/:id", renamed.status === 200 && renamed.body.name === "Smoke Mac 2", renamed);

const reg = await api("POST", "/v1/hosts/register", { token, body: { host_name: "Registered Mac", platform: "macos", app_version: "0.0.1" } });
check("POST /v1/hosts/register", reg.status === 200 && reg.body.host_token, reg);

// ice
const iceUser = await api("GET", "/v1/ice", { token });
check("GET /v1/ice (user)", iceUser.status === 200 && iceUser.body.ice_servers.length > 0 && iceUser.body.ttl > 0, iceUser);
const turn = iceUser.body.ice_servers.some((s: any) => s.urls.some((u: string) => u.startsWith("turn")));
console.log(`     ice servers: ${turn ? "STUN + TURN" : "STUN only"}`);
check("GET /v1/ice (host)", (await api("GET", "/v1/ice", { token: hostToken })).status === 200);
check("GET /v1/ice without token is 401", (await api("GET", "/v1/ice")).status === 401);

// signaling
const phone = new Peer(`phone-${crypto.randomUUID().slice(0, 8)}`);
const mac = new Peer(`host-${hostId}`);
check("signal: phone may not use a host peer id", (await upgradeStatus("peer=host-evil", token)) === 400);
const w1 = await phone.open(token);
check("signal: phone welcome", w1.peer.id === phone.id && w1.peer.kind === "phone" && Array.isArray(w1.peers), w1);

const presence = phone.next((m) => m.type === "presence" && m.peers.some((p: any) => p.id === mac.id));
const w2 = await mac.open(hostToken, true);
check("signal: host welcome lists the phone", w2.peer.id === `host-${hostId}` && w2.peer.kind === "host" && w2.peer.host_id === hostId && w2.peers.some((p: any) => p.id === phone.id), w2);
const pr = await presence;
check("signal: phone sees host presence", pr.peers.some((p: any) => p.id === mac.id && p.kind === "host" && p.name === "Smoke Mac 2"), pr);

hosts = await api("GET", "/v1/hosts", { token });
check("GET /v1/hosts (online from room)", hosts.body.hosts.some((h: any) => h.id === hostId && h.online === true), hosts);

const offer = { kind: "offer", sdp: "v=0 smoke" };
phone.send({ type: "signal", to: mac.id, session: "s1", payload: offer });
const got = await mac.next((m) => m.type === "signal");
check("signal: phone -> host relay", got.from === phone.id && got.session === "s1" && got.payload.sdp === offer.sdp, got);

mac.send({ type: "signal", to: phone.id, session: "s1", payload: { kind: "answer", sdp: "v=0 answer" } });
const ans = await phone.next((m) => m.type === "signal");
check("signal: host -> phone relay", ans.from === mac.id && ans.payload.kind === "answer", ans);

phone.send({ type: "signal", to: "nobody", session: "s1", payload: {} });
const off = await phone.next((m) => m.type === "error");
check("signal: unknown target is peer_offline", off.code === "peer_offline" && off.to === "nobody", off);

phone.send('{"type":"ping"}');
check("signal: ping auto-response", (await phone.next((m) => m.type === "pong")).type === "pong");

const left = phone.next((m) => m.type === "presence" && !m.peers.some((p: any) => p.id === mac.id));
mac.close();
check("signal: presence after host disconnect", await left);
phone.close();

// cleanup
check("DELETE /v1/hosts/:id", (await api("DELETE", `/v1/hosts/${hostId}`, { token })).body.ok === true);
check("deleted host token is rejected", (await api("GET", "/v1/host/me", { token: hostToken })).status === 401);
check("POST /v1/auth/logout", (await api("POST", "/v1/auth/logout", { body: { refresh_token: session.refresh_token } })).body.ok === true);
check("logged-out refresh token is rejected", (await api("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } })).status === 401);
check("DELETE /v1/me", (await api("DELETE", "/v1/me", { token })).body.ok === true);
check("deleted account token is rejected", (await api("GET", "/v1/me", { token })).status === 401);
check("deleted account cannot connect to signaling", (await upgradeStatus("peer=phone-x", token)) === 401);

console.log(`\nsmoke passed: ${passed} checks`);
process.exit(0);
