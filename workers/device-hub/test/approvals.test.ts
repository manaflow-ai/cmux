import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalJson, decisionMessage } from "../src/approvals";
import { base64Decode, sha256Hex, verifyDeviceSignature } from "../src/crypto";
import { apnsAnswers, apnsCalls, auditEvents, BASE, Device, hubEnv, signIn, waitFor, worker } from "./helpers";

// Computer Use approvals (PROTOCOL.md, Computer Use approvals): a machine asks,
// another device of the user answers with a signature the machine can check.

function nonce(): string {
  return [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function question(overrides: Record<string, unknown> = {}, target: Record<string, unknown> = {}) {
  const now = Date.now();
  const request: Record<string, unknown> = {
    v: 1,
    nonce: nonce(),
    client: "com.cmuxterm.app.debug.cu1",
    machine: "build-box-7",
    session: "c-41",
    agent: "Claude",
    workspace: "api-server",
    target: { bundle_id: null, executable: "/usr/bin/gedit", name: "Text Editor", ...target },
    tool: "click",
    risk: "R1",
    created_ms: now,
    wait_until_ms: now + 120_000,
    answerable_until_ms: now + 600_000,
    ...overrides,
  };
  request.digest = await sha256Hex(canonicalJson(request));
  return request;
}

/** A user with a Linux box that asks, a Mac and an iPhone that answer, and a Windows box; all connected. */
async function family() {
  const account = await signIn();
  const box = await Device.create(account, "build-box-7", "linux");
  const mac = await Device.create(account, "Studio", "macos");
  const phone = await Device.create(account, "iPhone", "ios");
  const win = await Device.create(account, "win-11", "windows");
  for (const d of [box, mac, phone, win]) {
    await d.register();
    await d.connect();
  }
  return { account, box, mac, phone, win };
}

async function ask(asker: Device, request: Record<string, unknown>, allowAlways?: boolean) {
  return asker.call("POST", "/v1/approvals", allowAlways === undefined ? { request } : { request, allowAlways });
}

async function answer(decider: Device, id: string, digest: string, decision: string, opts: { sigBy?: Device; sigDecision?: string; sigDigest?: string } = {}) {
  const sig = await (opts.sigBy ?? decider).sign(decisionMessage(opts.sigDigest ?? digest, (opts.sigDecision ?? decision) as "once"));
  return decider.call("POST", `/v1/approvals/${id}/decision`, { decision, digest, sig });
}

describe("Computer Use approvals", () => {
  it("routes a question to the Mac and the phone and a signed answer back to the asking machine", async () => {
    const { box, mac, phone, win } = await family();
    const request = await question();
    const res = await ask(box, request);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const id = res.json.approval.id as string;
    expect(res.json.approval).toMatchObject({ deviceId: box.id, deviceName: "build-box-7", state: "pending", allowAlways: false, request });

    for (const d of [mac, phone]) {
      const f = await d.user!.next((m) => m.type === "approval.request");
      expect(f.approval).toMatchObject({ id, deviceId: box.id, deviceName: "build-box-7", allowAlways: false, request, answerableUntil: request.answerable_until_ms });
    }
    // Only approvers hear the question: not the asker, not another Windows or Linux machine.
    expect(await box.user!.none((m) => m.type === "approval.request")).toBe(true);
    expect(await win.user!.none((m) => m.type === "approval.request")).toBe(true);

    const pending = await phone.call("GET", "/v1/approvals");
    expect(pending.json.approvals.map((a: any) => a.id)).toEqual([id]);
    expect((await box.call("GET", "/v1/approvals")).json.approvals).toEqual([]);

    const decided = await answer(phone, id, request.digest as string, "session");
    expect(decided.status, JSON.stringify(decided.json)).toBe(200);
    expect(decided.json.approval).toMatchObject({ state: "decided", decision: "session", deciderId: phone.id });

    const msg = await box.user!.next((m) => m.type === "approval.decided");
    expect(msg).toMatchObject({ id, decision: "session", digest: request.digest, deciderId: phone.id });
    // The asking machine checks the signature with the decider's registered key itself.
    expect(await verifyDeviceSignature(phone.signingKey, msg.sig, decisionMessage(request.digest as string, "session"))).toBe(true);
    expect(await mac.user!.next((m) => m.type === "approval.closed")).toEqual({ type: "approval.closed", id, state: "decided", decision: "session" });
    expect(await phone.user!.none((m) => m.type === "approval.closed")).toBe(true);

    const read = await box.call("GET", `/v1/approvals/${id}`);
    expect(read.json.approval).toMatchObject({ state: "decided", decision: "session", deciderId: phone.id, sig: msg.sig });
    const events = await auditEvents(mac);
    expect(events.filter((e) => e.startsWith("cu_"))).toEqual(["cu_requested", "cu_decided"]);
    const entries = (await mac.call("GET", "/v1/audit?limit=10")).json.entries as any[];
    expect(entries.find((e) => e.event === "cu_decided")).toMatchObject({ hostId: box.id, viewerId: phone.id, sessionId: id, detail: "session", hostName: "build-box-7", viewerName: "iPhone" });
    expect(entries.find((e) => e.event === "cu_requested")).toMatchObject({ hostId: box.id, sessionId: id, detail: "click Text Editor" });
  });

  it("refuses an answer from the asking device itself, Mac or box", async () => {
    const { box, mac } = await family();
    const r1 = await question();
    const a1 = await ask(box, r1);
    const self1 = await answer(box, a1.json.approval.id, r1.digest as string, "once");
    expect(self1.status).toBe(403);
    expect(self1.json.error.code).toBe("self_approval");

    const r2 = await question();
    const a2 = await ask(mac, r2);
    expect(a2.status).toBe(200);
    const self2 = await answer(mac, a2.json.approval.id, r2.digest as string, "once");
    expect(self2.status).toBe(403);
    expect(self2.json.error.code).toBe("self_approval");
    expect((await box.call("GET", `/v1/approvals/${a2.json.approval.id}`)).json.approval.state).toBe("pending");
  });

  it("refuses an answer from a Windows or Linux machine", async () => {
    const { box, win } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id;
    const res = await answer(win, id, r.digest as string, "once");
    expect(res.status).toBe(403);
    expect(res.json.error.code).toBe("not_approver");
  });

  it("refuses a question whose digest is not its own canonical JSON", async () => {
    const { box } = await family();
    const r = await question();
    // Changed after the digest was taken: the Mac would show another app than the machine asked about.
    (r.target as Record<string, unknown>).name = "Terminal";
    const res = await ask(box, r);
    expect(res.status).toBe(400);
    expect(res.json.error.code).toBe("digest_mismatch");
  });

  it("refuses an answer for another digest, or with a signature that is not the decider's over this answer", async () => {
    const { box, mac, phone } = await family();
    const r = await question();
    const other = await question();
    const id = (await ask(box, r)).json.approval.id;

    const wrongDigest = await answer(phone, id, other.digest as string, "once");
    expect(wrongDigest.status).toBe(400);
    expect(wrongDigest.json.error.code).toBe("digest_mismatch");

    const otherKey = await answer(phone, id, r.digest as string, "once", { sigBy: mac });
    expect(otherKey.status).toBe(400);
    expect(otherKey.json.error.code).toBe("bad_decision_signature");

    // A signature over "deny" does not carry "once".
    const otherDecision = await answer(phone, id, r.digest as string, "once", { sigDecision: "deny" });
    expect(otherDecision.status).toBe(400);
    expect(otherDecision.json.error.code).toBe("bad_decision_signature");

    // A signature over another question's digest does not answer this one.
    const otherQuestion = await answer(phone, id, r.digest as string, "once", { sigDigest: other.digest as string });
    expect(otherQuestion.status).toBe(400);
    expect(otherQuestion.json.error.code).toBe("bad_decision_signature");

    const garbage = await phone.call("POST", `/v1/approvals/${id}/decision`, { decision: "once", digest: r.digest, sig: "AAAA" });
    expect(garbage.json.error.code).toBe("bad_decision_signature");

    expect(await box.user!.none((m) => m.type === "approval.decided")).toBe(true);
    expect((await box.call("GET", `/v1/approvals/${id}`)).json.approval.state).toBe("pending");
  });

  it("takes Always Allow only when the asking machine allows it", async () => {
    const { box, phone } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id;
    const refused = await answer(phone, id, r.digest as string, "always");
    expect(refused.status).toBe(403);
    expect(refused.json.error.code).toBe("always_not_allowed");

    const r2 = await question();
    const a2 = await ask(box, r2, true);
    expect(a2.json.approval.allowAlways).toBe(true);
    expect((await phone.user!.next((m) => m.type === "approval.request" && m.approval.id === a2.json.approval.id)).approval.allowAlways).toBe(true);
    const ok = await answer(phone, a2.json.approval.id, r2.digest as string, "always");
    expect(ok.status).toBe(200);
    expect((await box.user!.next((m) => m.type === "approval.decided")).decision).toBe("always");
  });

  it("takes one answer: a second answer and a replayed request are refused", async () => {
    const { box, mac, phone } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id;
    const sig = await phone.sign(decisionMessage(r.digest as string, "once"));
    const body = { decision: "once", digest: r.digest, sig };
    const first = await phone.call("POST", `/v1/approvals/${id}/decision`, body);
    expect(first.status).toBe(200);

    const second = await answer(mac, id, r.digest as string, "deny");
    expect(second.status).toBe(409);
    expect(second.json.error.code).toBe("approval_not_pending");

    // The phone's request again, byte for byte: the device signature is burned.
    const replayed = await phone.call("POST", `/v1/approvals/${id}/decision`, body, { headers: first.headers });
    expect(replayed.status).toBe(401);
    expect(replayed.json.error.code).toBe("replay");
    // Freshly signed, the same answer is still a second answer.
    const again = await phone.call("POST", `/v1/approvals/${id}/decision`, body);
    expect(again.status).toBe(409);

    await box.user!.next((m) => m.type === "approval.decided");
    expect(await box.user!.none((m) => m.type === "approval.decided")).toBe(true);
    expect((await box.call("GET", `/v1/approvals/${id}`)).json.approval).toMatchObject({ decision: "once", deciderId: phone.id });
  });

  it("expires at answerable_until_ms: no answer after it, every device hears it closed", async () => {
    const { box, mac, phone } = await family();
    const now = Date.now();
    const r = await question({ created_ms: now, wait_until_ms: now + 600, answerable_until_ms: now + 1200 });
    const id = (await ask(box, r)).json.approval.id;
    const closed = await mac.user!.next((m) => m.type === "approval.closed" && m.id === id, 5000);
    expect(closed).toEqual({ type: "approval.closed", id, state: "expired", decision: null });
    expect((await box.user!.next((m) => m.type === "approval.closed" && m.id === id)).state).toBe("expired");

    const late = await answer(phone, id, r.digest as string, "once");
    expect(late.status).toBe(409);
    expect(late.json.error.code).toBe("approval_not_pending");
    expect((await box.call("GET", `/v1/approvals/${id}`)).json.approval.state).toBe("expired");
    expect((await phone.call("GET", "/v1/approvals")).json.approvals).toEqual([]);
    expect((await auditEvents(mac)).filter((e) => e.startsWith("cu_"))).toEqual(["cu_requested", "cu_expired"]);
  });

  it("refuses an answer that arrives after the deadline even before the alarm runs", async () => {
    const { account, box, phone } = await family();
    const now = Date.now();
    const r = await question({ created_ms: now, wait_until_ms: now + 300, answerable_until_ms: now + 400 });
    const id = (await ask(box, r)).json.approval.id;
    // Hold the alarm back so the decision path itself sees the deadline.
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    await runInDurableObject(stub, async (_i, ctx) => {
      await ctx.storage.setAlarm(Date.now() + 60_000);
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const late = await answer(phone, id, r.digest as string, "once");
    expect(late.status).toBe(409);
    expect(late.json.error.code).toBe("approval_expired");
    expect((await box.call("GET", `/v1/approvals/${id}`)).json.approval.state).toBe("expired");
  });

  it("lets only the asking machine cancel its question", async () => {
    const { box, mac, phone } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id;
    const notAsker = await phone.call("DELETE", `/v1/approvals/${id}`);
    expect(notAsker.status).toBe(403);
    expect(notAsker.json.error.code).toBe("not_asker");
    const cancel = await box.call("DELETE", `/v1/approvals/${id}`);
    expect(cancel.json.approval.state).toBe("cancelled");
    expect(await mac.user!.next((m) => m.type === "approval.closed")).toEqual({ type: "approval.closed", id, state: "cancelled", decision: null });
    const late = await answer(phone, id, r.digest as string, "once");
    expect(late.json.error.code).toBe("approval_not_pending");
  });

  it("returns the stored question for a retry and refuses the nonce on another question", async () => {
    const { box, phone } = await family();
    const r = await question();
    const first = await ask(box, r);
    const retry = await ask(box, r);
    expect(retry.status).toBe(200);
    expect(retry.json.approval.id).toBe(first.json.approval.id);
    expect((await phone.call("GET", "/v1/approvals")).json.approvals).toHaveLength(1);

    const reused = await question({ nonce: r.nonce, tool: "type_text" });
    const conflict = await ask(box, reused);
    expect(conflict.status).toBe(409);
    expect(conflict.json.error.code).toBe("approval_exists");
  });

  it("checks the question's shape and deadlines", async () => {
    const { box } = await family();
    const now = Date.now();
    const cases: [Record<string, unknown>, Record<string, unknown>][] = [
      [{ answerable_until_ms: now - 1, wait_until_ms: now - 1, created_ms: now - 2 }, {}],
      [{ answerable_until_ms: now + 16 * 60_000 }, {}],
      [{ wait_until_ms: now + 700_000 }, {}],
      [{ nonce: "short" }, {}],
      [{ v: 2 }, {}],
      [{ agent: "" }, {}],
      [{}, { executable: null }],
      [{ created_ms: 1.5 }, {}],
    ];
    for (const [overrides, target] of cases) {
      const res = await ask(box, await question(overrides, target).catch(async () => ({ ...(await question()), ...overrides })));
      expect(res.status, JSON.stringify(overrides)).toBe(400);
    }
  });

  it("removing the asking machine cancels its questions", async () => {
    const { box, mac } = await family();
    const id = (await ask(box, await question())).json.approval.id;
    await mac.user!.next((m) => m.type === "approval.request");
    expect((await mac.call("DELETE", `/v1/devices/${box.id}`)).status).toBe(200);
    expect(await mac.user!.next((m) => m.type === "approval.closed" && m.id === id)).toMatchObject({ state: "cancelled" });
  });

  it("a Mac's Deny closes the question on the phone", async () => {
    const { box, mac, phone } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id;
    const res = await answer(mac, id, r.digest as string, "deny");
    expect(res.status).toBe(200);
    expect(await phone.user!.next((m) => m.type === "approval.closed")).toEqual({ type: "approval.closed", id, state: "decided", decision: "deny" });
    expect((await box.user!.next((m) => m.type === "approval.decided")).decision).toBe("deny");
  });

  it("a Mac's host-scoped session (cmux Remote, app quit) asks, reads and cancels, and never decides", async () => {
    const { box, mac, phone } = await family();
    await mac.share(true);
    expect((await mac.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);
    const body = JSON.stringify({ userId: mac.account.userId });
    const headers = { ...(await mac.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
    const renewed = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
    const host = ((await renewed.json()) as any).session as string;

    const r = await question();
    const asked = await mac.call("POST", "/v1/approvals", { request: r }, { session: host });
    expect(asked.status, JSON.stringify(asked.json)).toBe(200);
    const id = asked.json.approval.id as string;
    expect((await mac.call("GET", `/v1/approvals/${id}`, undefined, { session: host })).status).toBe(200);
    expect((await mac.call("DELETE", `/v1/approvals/${id}`, undefined, { session: host })).json.approval.state).toBe("cancelled");

    const r2 = await question();
    const other = (await ask(box, r2)).json.approval.id as string;
    const sig = await mac.sign(decisionMessage(r2.digest as string, "once"));
    // Another machine's question is not this Mac's to read, list or answer.
    for (const path of [`/v1/approvals/${other}`, "/v1/approvals"]) {
      const read = await mac.call("GET", path, undefined, { session: host });
      expect(read.status, path).toBe(403);
      expect(read.json.error.code).toBe("host_scope");
    }
    const decide = await mac.call("POST", `/v1/approvals/${other}/decision`, { decision: "once", digest: r2.digest, sig }, { session: host });
    expect(decide.status).toBe(403);
    expect(decide.json.error.code).toBe("host_scope");
    const cancelOther = await mac.call("DELETE", `/v1/approvals/${other}`, undefined, { session: host });
    expect(cancelOther.json.error.code).toBe("host_scope");
    expect((await phone.call("GET", "/v1/approvals")).json.approvals.map((a: any) => a.id)).toEqual([other]);
  });
  it("caps a machine's open questions", async () => {
    const { box } = await family();
    for (let i = 0; i < 32; i++) expect((await ask(box, await question())).status).toBe(200);
    const res = await ask(box, await question());
    expect(res.status).toBe(429);
    expect(res.json.error.code).toBe("rate_limited");
  });

  it("refuses a copy of another machine's open question", async () => {
    const { box, win } = await family();
    const r = await question();
    expect((await ask(box, r)).status).toBe(200);
    // Same nonce and digest from another device: an answer to the copy would verify for the original.
    const copy = await ask(win, r);
    expect(copy.status).toBe(409);
    expect(copy.json.error.code).toBe("approval_exists");
  });

  it("refuses a string Swift and Rust cannot hold (a lone surrogate)", async () => {
    const { box } = await family();
    const r = await question();
    (r.target as Record<string, unknown>).name = "Safari \ud800";
    const res = await ask(box, r);
    expect(res.status).toBe(400);
    expect(res.json.error.code).toBe("bad_request");
  });

  it("deletes a closed question an hour after its deadline; the audit stays", async () => {
    const { account, box, phone } = await family();
    const r = await question();
    const id = (await ask(box, r)).json.approval.id as string;
    expect((await answer(phone, id, r.digest as string, "once")).status).toBe(200);
    const stub = hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(account.userId));
    await runInDurableObject(stub, async (instance: any, ctx) => {
      ctx.storage.sql.exec("UPDATE approvals SET answerable_until = ? WHERE id = ?", Date.now() - 3600_001, id);
      await instance.alarm();
    });
    expect((await box.call("GET", `/v1/approvals/${id}`)).status).toBe(404);
    expect((await auditEvents(phone)).filter((e) => e.startsWith("cu_"))).toEqual(["cu_requested", "cu_decided"]);
  });
});

describe("device registration for Computer Use machines", () => {
  it("registers Windows and Linux machines with their key assurance", async () => {
    const account = await signIn();
    const win = await Device.create(account, "win-11", "windows");
    await win.register();
    const linux = await Device.create(account, "fedora", "linux");
    const res = await linux.call("POST", "/v1/devices", { id: linux.id, name: "fedora", platform: "linux", signingKey: linux.signingKey, agreementKey: linux.agreementKey, assurance: "keystore" });
    expect(res.json.device).toMatchObject({ platform: "linux", assurance: "keystore" });
    const mac = await Device.create(account, "Studio", "macos");
    await mac.register();
    const list = (await mac.call("GET", "/v1/devices")).json.devices as any[];
    expect(Object.fromEntries(list.map((d) => [d.name, d.assurance]))).toEqual({ "win-11": "file", fedora: "keystore", Studio: "hardware" });

    const bad = await Device.create(account, "x", "linux");
    const refused = await bad.call("POST", "/v1/devices", { id: bad.id, name: "x", platform: "linux", signingKey: bad.signingKey, agreementKey: bad.agreementKey, assurance: "tpm" });
    expect(refused.status).toBe(400);
    const unknown = await bad.call("POST", "/v1/devices", { id: bad.id, name: "x", platform: "freebsd", signingKey: bad.signingKey, agreementKey: bad.agreementKey });
    expect(unknown.status).toBe(400);
  });

  it("never changes a device's platform or raises its key assurance", async () => {
    const account = await signIn();
    const box = await Device.create(account, "box", "linux");
    const reg = (platform: string, assurance?: string) =>
      box.call("POST", "/v1/devices", { id: box.id, name: "box", platform, signingKey: box.signingKey, agreementKey: box.agreementKey, ...(assurance ? { assurance } : {}) });
    expect((await reg("linux", "keystore")).status).toBe(200);
    // A box that says it is a Mac would become an approver.
    const asMac = await reg("macos", "hardware");
    expect(asMac.status).toBe(409);
    expect(asMac.json.error.code).toBe("device_platform_mismatch");
    expect((await reg("linux", "hardware")).json.error.code).toBe("device_platform_mismatch");
    expect((await reg("linux", "file")).json.device.assurance).toBe("file");
    expect((await reg("linux", "keystore")).status).toBe(409);
  });
});

describe("approval pushes to phones (APNs)", () => {
  const token = () => [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("");

  it("registers a phone's token and pushes each question to it", async () => {
    const { box, mac, phone } = await family();
    const t = token();
    const reg = await phone.call("PUT", `/v1/devices/${phone.id}/push`, { token: t, topic: "dev.cmux.mobile.prod", environment: "development" });
    expect(reg.status, JSON.stringify(reg.json)).toBe(200);
    expect(reg.json.push).toEqual({ registered: true, configured: true });

    const r = await question({ agent: "Claude\u0007" }, { name: "Safari" });
    const id = (await ask(box, r, true)).json.approval.id;
    const call = await waitFor(
      async () => apnsCalls.find((c) => c.token === t),
      (c) => !!c,
    );
    expect(call!.sandbox).toBe(true);
    expect(call!.headers).toMatchObject({
      "apns-topic": "dev.cmux.mobile.prod",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": `cu-${id}`,
      "apns-expiration": String(Math.floor((r.answerable_until_ms as number) / 1000)),
    });
    expect(call!.headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    const [h] = call!.headers.authorization!.slice(7).split(".");
    expect(JSON.parse(new TextDecoder().decode(base64Decode(h!.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - (h!.length % 4)) % 4))))).toEqual({ alg: "ES256", kid: "APNSKEY001" });
    expect(call!.body).toEqual({
      aps: {
        alert: { title: "Claude wants to use Safari", subtitle: "build-box-7", body: "api-server · click" },
        sound: "default",
        category: "CMUX_COMPUTER_USE_APPROVAL",
        "interruption-level": "time-sensitive",
        "thread-id": `cu:${box.id}`,
        "mutable-content": 1,
      },
      cmuxComputerUse: { v: 1, approvalId: id, deviceId: box.id, hub: "https://hub.test", allowAlways: true, answerableUntil: r.answerable_until_ms },
    });
    // The Mac has no token: it hears the question on its socket only.
    await mac.user!.next((m) => m.type === "approval.request");
    expect(apnsCalls.filter((c) => c.body?.cmuxComputerUse?.approvalId === id)).toHaveLength(1);
  });

  it("forgets a token APNs says is gone", async () => {
    const { box, phone } = await family();
    const t = token();
    apnsAnswers.set(t, { status: 410, reason: "Unregistered" });
    await phone.call("PUT", `/v1/devices/${phone.id}/push`, { token: t, topic: "dev.cmux.mobile.prod", environment: "production" });
    await ask(box, await question());
    await waitFor(async () => apnsCalls.filter((c) => c.token === t).length, (n) => n === 1);
    await ask(box, await question());
    // The second question finds no token to push to.
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(apnsCalls.filter((c) => c.token === t)).toHaveLength(1);
  });

  it("takes a push token only from the phone itself, for a known topic", async () => {
    const { mac, phone } = await family();
    const t = token();
    const other = await mac.call("PUT", `/v1/devices/${phone.id}/push`, { token: t, topic: "dev.cmux.mobile.prod", environment: "production" });
    expect(other.status).toBe(403);
    expect(other.json.error.code).toBe("not_self");
    const notPhone = await mac.call("PUT", `/v1/devices/${mac.id}/push`, { token: t, topic: "dev.cmux.mobile.prod", environment: "production" });
    expect(notPhone.status).toBe(400);
    const topic = await phone.call("PUT", `/v1/devices/${phone.id}/push`, { token: t, topic: "com.example.other", environment: "production" });
    expect(topic.status).toBe(400);
    const cleared = await phone.call("PUT", `/v1/devices/${phone.id}/push`, { token: null });
    expect(cleared.json.push.registered).toBe(false);
  });
});
