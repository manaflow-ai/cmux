#!/usr/bin/env bun
// Live end-to-end smoke for the dor/1 AccountRelay Durable Object.
//
// Signs into Stack with a real dev account and drives the ACCOUNT-scoped
// relay: two Macs park host legs on the SAME account object, phones bind to
// one Mac each. Proves: connect latency, bidirectional relay with leg-id
// stamping, ping RTT, ack/ackup pruning, in-band auth refresh, the resume
// contract in both directions (a dropped leg redials with resume+ack and
// receives exactly the missed frames), host-away buffering, fresh-host
// stale-stream clearing, and per-Mac isolation inside the one object
// (cross-Mac injection is a protocol error; traffic never leaks between
// Macs). Exits non-zero on any failed check.
//
// Env: DOR_BASE_URL, STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY,
//      CMUX_SMOKE_EMAIL, CMUX_SMOKE_PASSWORD, optional STACK_API_URL.

const BASE = required("DOR_BASE_URL").replace(/\/$/, "");
const STACK_API_URL = (process.env.STACK_API_URL ?? "https://api.stack-auth.com").replace(/\/$/, "");
const PROJECT_ID = required("STACK_PROJECT_ID");
const CLIENT_KEY = required("STACK_PUBLISHABLE_CLIENT_KEY");
const EMAIL = required("CMUX_SMOKE_EMAIL");
const PASSWORD = required("CMUX_SMOKE_PASSWORD");

const MAC_A = `smoke-mac-a-${Date.now()}`;
const MAC_B = `smoke-mac-b-${Date.now()}`;
const PHONE_1 = "smoke-phone-1";
const PHONE_2 = "smoke-phone-2";
const DATA_HEADER_BYTES = 14;

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    console.error(`missing env ${name}`);
    process.exit(2);
  }
  return value;
}

function dataFrame(legId: number, seq: number, payload: string): Uint8Array {
  const body = new TextEncoder().encode(payload);
  const frame = new Uint8Array(DATA_HEADER_BYTES + body.length);
  const view = new DataView(frame.buffer);
  view.setUint8(0, 1);
  view.setUint8(1, 1);
  view.setUint32(2, legId);
  view.setBigUint64(6, BigInt(seq));
  frame.set(body, DATA_HEADER_BYTES);
  return frame;
}

function parseData(buffer: ArrayBuffer): { legId: number; seq: number; payload: string } {
  const view = new DataView(buffer);
  return {
    legId: view.getUint32(2),
    seq: Number(view.getBigUint64(6)),
    payload: new TextDecoder().decode(new Uint8Array(buffer, DATA_HEADER_BYTES)),
  };
}

interface Leg {
  ws: WebSocket;
  legId: number;
  resumeKey: string;
  epoch: string;
  peerOnline: boolean;
  replayed: number;
  connectMs: number;
  controls: Array<Record<string, unknown>>;
  datas: Array<{ legId: number; seq: number; payload: string }>;
  waiters: Array<() => void>;
  closed: Promise<{ code: number; reason: string }>;
}

async function openLeg(
  role: "host" | "connect",
  device: string,
  mac: string,
  token: string,
  resume?: { key: string; ack?: number; acks?: Record<string, number> },
): Promise<Leg> {
  const query = role === "host" ? `device=${device}` : `device=${device}&mac=${mac}`;
  const url = `${BASE.replace(/^http/, "ws")}/v1/dor/${role}?${query}`;
  const started = performance.now();
  const ws = new WebSocket(url, { headers: { authorization: `Bearer ${token}` } } as never);
  ws.binaryType = "arraybuffer";
  const leg: Partial<Leg> & Pick<Leg, "controls" | "datas" | "waiters"> = {
    controls: [],
    datas: [],
    waiters: [],
  };
  let closeResolve!: (value: { code: number; reason: string }) => void;
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    closeResolve = resolve;
  });
  ws.addEventListener("close", (event) => closeResolve({ code: event.code, reason: event.reason }));
  ws.addEventListener("message", (event) => {
    if (typeof event.data === "string") {
      leg.controls!.push(JSON.parse(event.data));
    } else {
      leg.datas!.push(parseData(event.data as ArrayBuffer));
    }
    for (const wake of leg.waiters!.splice(0)) wake();
  });
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error(`${role} leg failed to connect`)));
  });
  ws.send(
    JSON.stringify({
      t: "hello",
      proto: "dor/1",
      device,
      ...(resume ? { resume: resume.key } : {}),
      ...(resume?.ack !== undefined ? { ack: resume.ack } : {}),
      ...(resume?.acks !== undefined ? { acks: resume.acks } : {}),
    }),
  );
  const ack = await waitControl(leg as Leg, (frame) => frame.t === "hello.ack" || frame.t === "resume.failed");
  if (ack.t === "resume.failed") throw new Error(`resume failed: ${ack.reason}`);
  leg.ws = ws;
  leg.legId = ack.legId as number;
  leg.resumeKey = ack.resumeKey as string;
  leg.epoch = ack.epoch as string;
  leg.peerOnline = ack.peerOnline as boolean;
  leg.replayed = (ack.replayed as number) ?? 0;
  leg.connectMs = performance.now() - started;
  leg.closed = closed;
  return leg as Leg;
}

async function waitControl(
  leg: Pick<Leg, "controls" | "waiters">,
  predicate: (frame: Record<string, unknown>) => boolean,
  timeoutMs = 10_000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const found = leg.controls.find(predicate);
    if (found) {
      leg.controls.splice(leg.controls.indexOf(found), 1);
      return found;
    }
    if (Date.now() > deadline) throw new Error("timed out waiting for control frame");
    await new Promise<void>((resolve) => {
      leg.waiters.push(resolve);
      setTimeout(resolve, 250);
    });
  }
}

async function waitData(
  leg: Pick<Leg, "datas" | "waiters">,
  count: number,
  timeoutMs = 10_000,
): Promise<Array<{ legId: number; seq: number; payload: string }>> {
  const deadline = Date.now() + timeoutMs;
  while (leg.datas.length < count) {
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${count} data frames (have ${leg.datas.length})`);
    }
    await new Promise<void>((resolve) => {
      leg.waiters.push(resolve);
      setTimeout(resolve, 250);
    });
  }
  return leg.datas.splice(0, count);
}

function quiet(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function check(name: string, ok: boolean, detail = ""): void {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
  if (!ok) failed = true;
}

const results: Array<{ name: string; ok: boolean; detail: string }> = [];
let failed = false;

// ---- sign in ----
const signIn = await fetch(`${STACK_API_URL}/api/v1/auth/password/sign-in`, {
  method: "POST",
  headers: {
    "x-stack-access-type": "client",
    "x-stack-project-id": PROJECT_ID,
    "x-stack-publishable-client-key": CLIENT_KEY,
    "content-type": "application/json",
  },
  body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
});
if (!signIn.ok) {
  console.error(`stack sign-in failed: ${signIn.status} ${await signIn.text()}`);
  process.exit(2);
}
const token = ((await signIn.json()) as { access_token: string }).access_token;
console.log("signed in");

// ---- unauthenticated dial is refused at the edge ----
{
  const url = `${BASE.replace(/^http/, "ws")}/v1/dor/connect?device=x&mac=y`;
  const refused = await new Promise<boolean>((resolve) => {
    const ws = new WebSocket(url);
    ws.addEventListener("open", () => resolve(false));
    ws.addEventListener("error", () => resolve(true));
    setTimeout(() => resolve(true), 5000);
  });
  check("unauthenticated dial refused", refused);
}

// ---- host + phone legs on the ONE account object ----
const hostA = await openLeg("host", MAC_A, MAC_A, token);
check("mac A host connect under 2s", hostA.connectMs < 2000, `${hostA.connectMs.toFixed(0)}ms`);

const phone1 = await openLeg("connect", PHONE_1, MAC_A, token);
check("phone connect under 2s", phone1.connectMs < 2000, `${phone1.connectMs.toFixed(0)}ms`);
check("phone sees its mac online", phone1.peerOnline);

const online1 = await waitControl(hostA, (frame) => frame.t === "peer.online");
check("mac A notified of its phone", online1.legId === phone1.legId && online1.device === PHONE_1);

// ---- second Mac + phone on the SAME object: scoped presence ----
const hostB = await openLeg("host", MAC_B, MAC_B, token);
check("mac B host joins same account object", hostB.legId !== hostA.legId);
check("mac B sees no phones yet", hostB.peerOnline === false);
const phone2 = await openLeg("connect", PHONE_2, MAC_B, token);
check("phone 2 sees mac B online", phone2.peerOnline);
const online2 = await waitControl(hostB, (frame) => frame.t === "peer.online");
check("mac B notified of phone 2 only", online2.legId === phone2.legId && online2.device === PHONE_2);

// ---- data relay both ways, with leg stamping ----
phone1.ws.send(dataFrame(0, 1, "up-1"));
phone1.ws.send(dataFrame(0, 2, "up-2"));
const uploadsA = await waitData(hostA, 2);
check(
  "phone uploads stamped with phone leg id",
  uploadsA.every((d) => d.legId === phone1.legId) &&
    uploadsA[0]!.payload === "up-1" &&
    uploadsA[1]!.payload === "up-2",
);
const ackup1 = await waitControl(phone1, (frame) => frame.t === "ackup" && (frame.seq as number) >= 2);
check("phone gets ackup through seq 2", ackup1.seq === 2);

hostA.ws.send(dataFrame(phone1.legId, 1, "down-1"));
const downs = await waitData(phone1, 1);
check("mac download reaches its phone", downs[0]!.payload === "down-1" && downs[0]!.seq === 1);
const ackupHost = await waitControl(hostA, (frame) => frame.t === "ackup" && frame.leg === phone1.legId);
check("mac gets per-destination ackup", ackupHost.seq === 1);

// ---- per-Mac isolation inside the one object ----
{
  // Nothing sent for mac B so far may have leaked anywhere.
  check("mac B saw none of mac A's traffic", hostB.datas.length === 0 && phone2.datas.length === 0);
  // Mac B tries to inject into phone 1 (bound to mac A): protocol error.
  hostB.ws.send(dataFrame(phone1.legId, 1, "evil"));
  const closedB = await hostB.closed;
  check("cross-mac injection closes the offending host leg", closedB.code === 4400, `code=${closedB.code}`);
  await quiet(300);
  check("phone 1 never received the injected frame", phone1.datas.length === 0);
  const offline2 = await waitControl(phone2, (frame) => frame.t === "peer.offline");
  check("phone 2 told its mac went offline", typeof offline2.reason === "string");
}

// ---- ping RTT ----
{
  const t0 = performance.now();
  phone1.ws.send(JSON.stringify({ t: "ping", ts: 123.5 }));
  const pong = await waitControl(phone1, (frame) => frame.t === "pong");
  check("pong echoes ts", pong.ts === 123.5, `${(performance.now() - t0).toFixed(0)}ms rtt`);
}

// ---- in-band auth refresh ----
{
  phone1.ws.send(JSON.stringify({ t: "auth.refresh", token }));
  const ok = await waitControl(phone1, (frame) => frame.t === "auth.ok");
  check("auth refresh extends deadline", typeof ok.deadline === "number" && (ok.deadline as number) > Date.now());
  phone1.ws.send(JSON.stringify({ t: "auth.refresh", token: "garbage" }));
  // A garbage token must close the leg, never extend it.
  const closed = await phone1.closed;
  check("bad refresh token closes the leg", closed.code === 4401, `code=${closed.code}`);
}

// ---- phone resume: relay replays exactly the missed downloads ----
{
  // Phone 1's socket is now closed (bad-auth test) with download seq 1 acked
  // nowhere — its last received was seq 1. The mac sends 2 more while the
  // phone is away; resume must replay exactly those.
  hostA.ws.send(dataFrame(phone1.legId, 2, "down-2"));
  hostA.ws.send(dataFrame(phone1.legId, 3, "down-3"));
  await waitControl(hostA, (frame) => frame.t === "ackup" && frame.seq === 3);
  const resumed = await openLeg("connect", PHONE_1, MAC_A, token, { key: phone1.resumeKey, ack: 1 });
  check("phone resume keeps the leg id", resumed.legId === phone1.legId);
  check("phone resume reports replay count", resumed.replayed === 2, `replayed=${resumed.replayed}`);
  const replays = await waitData(resumed, 2);
  check(
    "phone resume replays exactly the gap",
    replays[0]!.payload === "down-2" && replays[1]!.payload === "down-3" && replays[1]!.seq === 3,
  );
  // Continue the same upload stream: seq continues, no dedupe confusion.
  resumed.ws.send(dataFrame(0, 3, "up-3"));
  const post = await waitData(hostA, 1);
  check("resumed phone keeps its upload stream", post[0]!.payload === "up-3" && post[0]!.legId === phone1.legId);
  resumed.ws.close(1000, "smoke done");
  await quiet(300);
}

// ---- host-away buffering + host resume with per-source acks ----
{
  const phone = await openLeg("connect", PHONE_1, MAC_A, token);
  // Drop the mac's socket abruptly; its phone keeps uploading meanwhile.
  hostA.ws.close(1000, "smoke: host away");
  await waitControl(phone, (frame) => frame.t === "peer.offline");
  phone.ws.send(dataFrame(0, 1, "buffered-1"));
  phone.ws.send(dataFrame(0, 2, "buffered-2"));
  await waitControl(phone, (frame) => frame.t === "ackup" && frame.seq === 2);
  // Host resumes claiming nothing received from this phone leg yet.
  const resumedHost = await openLeg("host", MAC_A, MAC_A, token, {
    key: hostA.resumeKey,
    acks: { [String(phone.legId)]: 0 },
  });
  check("host resume keeps the leg alive", resumedHost.replayed >= 2, `replayed=${resumedHost.replayed}`);
  const buffered = await waitData(resumedHost, 2);
  check(
    "uploads sent while mac away replay into its resume",
    buffered[0]!.payload === "buffered-1" && buffered[1]!.payload === "buffered-2",
  );
  const back = await waitControl(phone, (frame) => frame.t === "peer.online");
  check("phone told its mac is back", back !== null);

  // ---- fresh host session clears stale host-destined streams ----
  phone.ws.send(dataFrame(0, 3, "stale-for-old-process"));
  await waitControl(phone, (frame) => frame.t === "ackup" && frame.seq === 3);
  resumedHost.ws.close(1000, "smoke: host gone for good");
  await waitControl(phone, (frame) => frame.t === "peer.offline");
  const freshHost = await openLeg("host", MAC_A, MAC_A, token); // no resume: fresh session
  check("fresh host starts a new leg", freshHost.legId !== resumedHost.legId);
  await quiet(500);
  check("fresh host does NOT receive stale ciphertext", freshHost.datas.length === 0);
  // The phone's old upload stream is dead with the old process; a fresh phone
  // session (new leg) talks to the new one.
  phone.ws.close(1000, "smoke done");
  const freshPhone = await openLeg("connect", PHONE_1, MAC_A, token);
  freshPhone.ws.send(dataFrame(0, 1, "fresh-up"));
  const freshUp = await waitData(freshHost, 1);
  check("fresh phone reaches fresh host", freshUp[0]!.payload === "fresh-up" && freshUp[0]!.legId === freshPhone.legId);

  // ---- acks prune the ring so resume floor moves ----
  freshHost.ws.send(dataFrame(freshPhone.legId, 1, "d1"));
  freshHost.ws.send(dataFrame(freshPhone.legId, 2, "d2"));
  await waitData(freshPhone, 2);
  freshPhone.ws.send(JSON.stringify({ t: "ack", seq: 2 }));
  await quiet(300);
  // Resume claiming ack=0 must now FAIL: seq 1-2 were pruned by the ack, the
  // gap (0,2] is no longer provable — fail closed, never silently gap.
  freshPhone.ws.close(1000, "smoke: drop for failed resume");
  await quiet(300);
  const url = `${BASE.replace(/^http/, "ws")}/v1/dor/connect?device=${PHONE_1}&mac=${MAC_A}`;
  const ws = new WebSocket(url, { headers: { authorization: `Bearer ${token}` } } as never);
  ws.binaryType = "arraybuffer";
  const outcome = await new Promise<string>((resolve) => {
    ws.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const frame = JSON.parse(event.data) as { t: string; reason?: string };
      if (frame.t === "resume.failed") resolve(`resume.failed:${frame.reason}`);
      if (frame.t === "hello.ack") resolve("hello.ack");
    });
    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({ t: "hello", proto: "dor/1", device: PHONE_1, resume: freshPhone.resumeKey, ack: 0 }));
    });
    setTimeout(() => resolve("timeout"), 8000);
  });
  check("unprovable gap fails the resume (never silently skips)", outcome.startsWith("resume.failed"), outcome);
  freshHost.ws.close(1000, "smoke done");
}

// ---- wrap up ----
console.log("");
const passed = results.filter((r) => r.ok).length;
console.log(`${passed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
