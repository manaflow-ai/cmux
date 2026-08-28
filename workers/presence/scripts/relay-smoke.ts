#!/usr/bin/env bun
// Live end-to-end smoke test for the dot/1 MacRelay Durable Object.
//
// Signs into Stack with a real dev account, opens a host leg and a phone leg
// against a deployed worker, and proves: connect latency, bidirectional data
// relay with leg-id stamping, ping RTT, in-band auth refresh, and the resume
// contract (a dropped phone leg redials with resume+ack and receives exactly
// the missed frames). Exits non-zero on any failed check.
//
// Env: RELAY_BASE_URL, STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY,
//      CMUX_SMOKE_EMAIL, CMUX_SMOKE_PASSWORD, optional STACK_API_URL and
//      RELAY_SOAK_MINUTES (keeps the resumed legs continuously engaged).

const BASE = required("RELAY_BASE_URL").replace(/\/$/, "");
const STACK_API_URL = (process.env.STACK_API_URL ?? "https://api.stack-auth.com").replace(/\/$/, "");
const PROJECT_ID = required("STACK_PROJECT_ID");
const CLIENT_KEY = required("STACK_PUBLISHABLE_CLIENT_KEY");
const EMAIL = required("CMUX_SMOKE_EMAIL");
const PASSWORD = required("CMUX_SMOKE_PASSWORD");
const SOAK_MINUTES = Number(process.env.RELAY_SOAK_MINUTES ?? "0");
if (!Number.isFinite(SOAK_MINUTES) || SOAK_MINUTES < 0) {
  console.error("RELAY_SOAK_MINUTES must be a non-negative number");
  process.exit(2);
}

const MAC = `smoke-mac-${Date.now()}`;
const PHONE = "smoke-phone-1";
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
  token: string,
  resume?: { key: string; ack?: number; acks?: Record<string, number> },
): Promise<Leg> {
  const url = `${BASE.replace(/^http/, "ws")}/v1/relay/${role}?mac=${MAC}&device=${device}`;
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
      proto: "dot/1",
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
    if (Date.now() > deadline) throw new Error(`timed out waiting for control frame`);
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
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${count} data frames (have ${leg.datas.length})`);
    await new Promise<void>((resolve) => {
      leg.waiters.push(resolve);
      setTimeout(resolve, 250);
    });
  }
  return leg.datas.splice(0, count);
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

// ---- host + phone legs ----
const host = await openLeg("host", MAC, token);
check("host connect (ws+hello) under 2s", host.connectMs < 2000, `${host.connectMs.toFixed(0)}ms`);

const phone = await openLeg("connect", PHONE, token);
check("phone connect (ws+hello) under 2s", phone.connectMs < 2000, `${phone.connectMs.toFixed(0)}ms`);
check("phone sees host online", phone.peerOnline);

const online = await waitControl(host, (frame) => frame.t === "peer.online");
check("host notified of phone leg", online.legId === phone.legId && online.device === PHONE);

// ---- data relay both ways ----
phone.ws.send(dataFrame(0, 1, "up-1"));
phone.ws.send(dataFrame(0, 2, "up-2"));
const uploads = await waitData(host, 2);
check(
  "phone→host frames stamped with phone leg id",
  uploads.every((frame) => frame.legId === phone.legId) &&
    uploads.map((frame) => frame.payload).join(",") === "up-1,up-2",
);

host.ws.send(dataFrame(phone.legId, 1, "down-1"));
const downloads = await waitData(phone, 1);
check("host→phone frame delivered", downloads[0]!.payload === "down-1" && downloads[0]!.seq === 1);

// ---- ping RTT ----
const pingStart = performance.now();
host.ws.send(JSON.stringify({ t: "ping", ts: Date.now() }));
await waitControl(host, (frame) => frame.t === "pong");
check("ping/pong", true, `${(performance.now() - pingStart).toFixed(0)}ms RTT`);

// ---- auth refresh ----
host.ws.send(JSON.stringify({ t: "auth.refresh", token }));
const refreshed = await waitControl(host, (frame) => frame.t === "auth.ok");
check("in-band auth refresh extends deadline", typeof refreshed.deadline === "number");

// ---- resume drill: phone drops, host keeps sending, phone resumes ----
phone.ws.send(JSON.stringify({ t: "ack", seq: 1 })); // ack down-1
await new Promise((resolve) => setTimeout(resolve, 300));
phone.ws.close(4000, "smoke: simulated drop");
await phone.closed;
const offline = await waitControl(host, (frame) => frame.t === "peer.offline");
check("host notified of phone drop", offline.legId === phone.legId);

host.ws.send(dataFrame(phone.legId, 2, "down-2"));
host.ws.send(dataFrame(phone.legId, 3, "down-3"));
await new Promise((resolve) => setTimeout(resolve, 300));

const resumed = await openLeg("connect", PHONE, token, { key: phone.resumeKey, ack: 1 });
check("resume rebinds the same leg id", resumed.legId === phone.legId, `leg ${resumed.legId}`);
check("resume replayed exactly the gap", resumed.replayed === 2, `${resumed.replayed} frames`);
const replayFrames = await waitData(resumed, 2);
check(
  "replayed frames are down-2, down-3 in order",
  replayFrames.map((frame) => frame.payload).join(",") === "down-2,down-3",
);
check("same epoch across resume", resumed.epoch === phone.epoch);

// post-resume liveness both ways
resumed.ws.send(dataFrame(0, 3, "up-3"));
const postResume = await waitData(host, 1);
check("post-resume phone→host works", postResume[0]!.payload === "up-3");

// ---- upload ingest acks (ackup) prune the sender's resend buffer ----
const ackup = await waitControl(resumed, (frame) => frame.t === "ackup" && (frame.seq as number) >= 3);
check("phone uploads get ackup", typeof ackup.seq === "number", `through seq ${ackup.seq}`);
const hostAckup = await waitControl(host, (frame) => frame.t === "ackup" && frame.leg === phone.legId);
check("host uploads get per-leg ackup", typeof hostAckup.seq === "number");

// ---- host-away buffering: phone uploads while the Mac is gone, host resumes ----
host.ws.send(JSON.stringify({ t: "ack", seq: 3, leg: phone.legId })); // host acks up-1..3
await new Promise((resolve) => setTimeout(resolve, 300));
host.ws.close(4000, "smoke: simulated mac drop");
await host.closed;
await waitControl(resumed, (frame) => frame.t === "peer.offline");
resumed.ws.send(dataFrame(0, 4, "up-4"));
resumed.ws.send(dataFrame(0, 5, "up-5"));
await waitControl(resumed, (frame) => frame.t === "ackup" && (frame.seq as number) >= 5);
check("uploads while host away are ring-durable (ackup)", true);

const hostBack = await openLeg("host", MAC, token, {
  key: host.resumeKey,
  acks: { [String(phone.legId)]: 3 },
});
check("host resume rebinds", hostBack.legId === host.legId);
check("host resume replays buffered uploads", hostBack.replayed === 2, `${hostBack.replayed} frames`);
const buffered = await waitData(hostBack, 2);
check(
  "buffered uploads arrive in order with phone leg id",
  buffered.map((frame) => frame.payload).join(",") === "up-4,up-5" &&
    buffered.every((frame) => frame.legId === phone.legId),
);
await waitControl(resumed, (frame) => frame.t === "peer.online");
check("phone notified host is back", true);

// ---- optional engaged soak on the same resumed legs ----
// This intentionally does not redial. Any interruption fails the next frame,
// pong, or auth-refresh wait instead of hiding instability behind recovery.
if (SOAK_MINUTES > 0) {
  const startedAt = Date.now();
  const deadline = startedAt + SOAK_MINUTES * 60_000;
  let tick = 0;
  let uploadSeq = 5;
  let downloadSeq = 3;
  console.log(`starting ${SOAK_MINUTES}-minute engaged relay soak`);

  while (Date.now() < deadline) {
    tick += 1;
    uploadSeq += 1;
    downloadSeq += 1;

    const uploadPayload = `soak-up-${uploadSeq}`;
    resumed.ws.send(dataFrame(0, uploadSeq, uploadPayload));
    const upload = await waitData(hostBack, 1);
    check(
      `soak ${tick}: phone→host`,
      upload[0]!.payload === uploadPayload && upload[0]!.legId === phone.legId,
    );

    const downloadPayload = `soak-down-${downloadSeq}`;
    hostBack.ws.send(dataFrame(phone.legId, downloadSeq, downloadPayload));
    const download = await waitData(resumed, 1);
    check(
      `soak ${tick}: host→phone`,
      download[0]!.payload === downloadPayload && download[0]!.seq === downloadSeq,
    );

    const pingStarted = performance.now();
    hostBack.ws.send(JSON.stringify({ t: "ping", ts: Date.now() }));
    await waitControl(hostBack, (frame) => frame.t === "pong");
    check(`soak ${tick}: ping/pong`, true, `${(performance.now() - pingStarted).toFixed(0)}ms RTT`);

    if (tick % 12 === 0) {
      hostBack.ws.send(JSON.stringify({ t: "auth.refresh", token }));
      resumed.ws.send(JSON.stringify({ t: "auth.refresh", token }));
      const [hostAuth, phoneAuth] = await Promise.all([
        waitControl(hostBack, (frame) => frame.t === "auth.ok"),
        waitControl(resumed, (frame) => frame.t === "auth.ok"),
      ]);
      check(
        `soak ${tick}: in-band auth refresh`,
        typeof hostAuth.deadline === "number" && typeof phoneAuth.deadline === "number",
      );
    }

    const elapsedSeconds = Math.round((Date.now() - startedAt) / 1000);
    console.log(`soak progress ${elapsedSeconds}s/${Math.round(SOAK_MINUTES * 60)}s`);
    const remainingMs = deadline - Date.now();
    if (remainingMs > 0) await new Promise((resolve) => setTimeout(resolve, Math.min(25_000, remainingMs)));
  }

  check(
    "engaged relay soak completed",
    resumed.ws.readyState === WebSocket.OPEN && hostBack.ws.readyState === WebSocket.OPEN,
    `${Math.round((Date.now() - startedAt) / 1000)}s`,
  );
}

// ---- teardown ----
resumed.ws.close(1000, "smoke done");
hostBack.ws.close(1000, "smoke done");

console.log(JSON.stringify({ ok: !failed, base: BASE, mac: MAC, results }, null, 2));
process.exit(failed ? 1 : 0);
