import { describe, expect, it } from "vitest";
import { platformUserIdFor } from "../src/machine";
import { Device, approvedSession, auditEvents, mockOutbound, platformMachines, rawCall, signIn } from "./helpers";

// Leo, 2026-11-16: "the screen sharing should just be able to come with as the bonus and be in the
// separate process from teh app so it doesn't have to restart the app to grant permissions or
// whatever you guys shoudl be able to just pass it back and forth". A share is a record any of the
// account's devices lists and moves (`GET /v1/sessions`, `POST /v1/sessions/:id/move`), and a host
// pushes its screen to another device (`POST /v1/sessions` with `viewerId`), a joined machine's
// daemon included, with no prompt and no app restart.

type Account = Awaited<ReturnType<typeof signIn>>;
const LINUX_BOX = "d".repeat(64);

async function device(account: Account, name: string, platform: "macos" | "ios" | "linux" = "macos", opts: { share?: boolean; machine?: string } = {}) {
  const d = await Device.create(account, name, platform);
  d.machine = opts.machine;
  await d.register();
  if (opts.share) await d.share(true);
  await d.connect();
  return d;
}

/** A Linux box the person joined, signed in with its machine credential (machine scope), shared and connected. */
async function joinedMachine(person: Account, name = "Box") {
  mockOutbound();
  const credential = `cmm_${crypto.randomUUID().replace(/-/g, "")}`;
  platformMachines.set(credential, {
    machineId: `machine_${crypto.randomUUID().slice(0, 8)}`,
    teamId: "team_01",
    userId: await platformUserIdFor("test-project", person.sub),
    expiresAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
  });
  const keys = await Device.create({ userId: person.userId, session: "" }, name, "linux");
  const res = await rawCall("POST", "/v1/auth/machine", { body: { credential, deviceId: keys.id } });
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  const machine = await Device.create({ userId: person.userId, session: res.json.session }, name, "linux");
  Object.assign(machine, { id: keys.id, signing: keys.signing, signingKey: keys.signingKey, agreementKey: keys.agreementKey, machine: LINUX_BOX });
  await machine.register();
  await machine.share(true);
  await machine.connect();
  return machine;
}

const ticketFor = (d: Device, sid: string) => d.user!.next((f) => f.type === "session.ticket" && f.sessionId === sid);
const list = async (d: Device) => {
  const res = await d.call("GET", "/v1/sessions");
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  return res.json.sessions as any[];
};
const move = (d: Device, sid: string, body: Record<string, unknown>) => d.call("POST", `/v1/sessions/${sid}/move`, body);

describe("GET /v1/sessions", () => {
  it("lists every live share for the app, oldest first, and only its own machine's for a machine session", async () => {
    const person = await signIn();
    const mac = await device(person, "Studio", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const phone = await device(person, "Phone", "ios");
    const box = await joinedMachine(person);
    const first = await approvedSession(mac, laptop, "view");
    const second = await phone.call("POST", "/v1/sessions", { hostId: box.id, scope: "full" });
    expect(second.json.session.state).toBe("approved");
    const sessions = await list(laptop);
    expect(sessions).toEqual([
      { id: first.sid, hostId: mac.id, hostName: "Studio", viewerId: laptop.id, viewerName: "Laptop", scope: "view", state: "approved", createdAt: expect.any(Number), startedAt: null, movedFrom: null },
      { id: second.json.session.id, hostId: box.id, hostName: "Box", viewerId: phone.id, viewerName: "Phone", scope: "full", state: "approved", createdAt: expect.any(Number), startedAt: null, movedFrom: null },
    ]);
    // The machine sees the share it hosts, not the one between two other devices.
    expect((await list(box)).map((s) => s.id)).toEqual([second.json.session.id]);
    // An ended share is not listed.
    await laptop.call("POST", `/v1/sessions/${first.sid}/end`, {});
    expect((await list(mac)).map((s) => s.id)).toEqual([second.json.session.id]);
  });
});

describe("POST /v1/sessions/:id/move", () => {
  it("hands the viewer side to another device: tickets pushed to the new pair, the old share ends as moved", async () => {
    const person = await signIn();
    const mac = await device(person, "Studio", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const phone = await device(person, "Phone", "ios");
    const { sid, vt } = await approvedSession(mac, laptop, "view");
    // A viewer's own request carries no push marker.
    expect(vt.pushed).toBeUndefined();
    expect(vt.movedFrom).toBeUndefined();
    const res = await move(laptop, sid, { viewerId: phone.id });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const moved = res.json.session;
    expect(moved).toEqual({ id: expect.any(String), state: "approved", scope: "view", hostId: mac.id, viewerId: phone.id, movedFrom: sid });
    expect(await ticketFor(phone, moved.id)).toMatchObject({ role: "viewer", scope: "view", pushed: true, movedFrom: sid, peer: { id: mac.id } });
    expect(await ticketFor(mac, moved.id)).toMatchObject({ role: "host", pushed: true, movedFrom: sid, peer: { id: phone.id } });
    for (const d of [laptop, mac]) {
      expect(await d.user!.next((f) => f.type === "session.ended" && f.sessionId === sid)).toEqual({ type: "session.ended", sessionId: sid, reason: "moved", movedTo: moved.id });
    }
    expect(await list(mac)).toEqual([expect.objectContaining({ id: moved.id, viewerId: phone.id, movedFrom: sid })]);
    expect(await auditEvents(mac, sid)).toEqual(["requested", "approved", "moved", "ended"]);
    expect(await auditEvents(mac, moved.id)).toEqual(["approved"]);
    // The old share is over: it cannot be moved again.
    expect((await move(laptop, sid, { viewerId: laptop.id })).json.error.code).toBe("session_not_active");
  });

  it("hands the host side to another device: the viewer now sees that screen", async () => {
    const person = await signIn();
    const mac = await device(person, "Studio", "macos", { share: true });
    const other = await device(person, "Mini", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const { sid } = await approvedSession(mac, laptop, "full");
    const res = await move(laptop, sid, { hostId: other.id });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const moved = res.json.session;
    expect(moved).toMatchObject({ state: "approved", scope: "full", hostId: other.id, viewerId: laptop.id, movedFrom: sid });
    expect(await ticketFor(laptop, moved.id)).toMatchObject({ role: "viewer", pushed: true, movedFrom: sid, peer: { id: other.id } });
    expect(await ticketFor(other, moved.id)).toMatchObject({ role: "host", pushed: true, movedFrom: sid, peer: { id: laptop.id } });
    for (const d of [laptop, mac]) {
      expect(await d.user!.next((f) => f.type === "session.ended" && f.sessionId === sid)).toMatchObject({ reason: "moved", movedTo: moved.id });
    }
  });

  it("never prompts: a move that would need the host's answer is refused and the old share keeps running", async () => {
    const person = await signIn();
    const mac = await device(person, "Studio", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const phone = await device(person, "Phone", "ios");
    const { sid } = await approvedSession(mac, laptop, "full");
    const refusedWith = async (body: Record<string, unknown>, status: number, code: string) => {
      const res = await move(laptop, sid, body);
      expect([res.status, res.json.error?.code]).toEqual([status, code]);
    };
    await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "ask" });
    await refusedWith({ viewerId: phone.id }, 409, "needs_approval");
    // View Only does not cover a Full Control share either.
    await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "view" });
    await refusedWith({ viewerId: phone.id }, 409, "needs_approval");
    await mac.call("PUT", `/v1/permissions/${mac.id}/${phone.id}`, { scope: "none" });
    await refusedWith({ viewerId: phone.id }, 403, "permission_none");
    // A host that does not share, and a host that is not connected.
    const unshared = await device(person, "Unshared");
    await refusedWith({ hostId: unshared.id }, 403, "not_shared");
    const offline = await Device.create(person, "Offline", "macos");
    await offline.register();
    await offline.share(true);
    await refusedWith({ hostId: offline.id }, 409, "host_offline");
    // Exactly one side moves.
    await refusedWith({}, 400, "bad_request");
    await refusedWith({ viewerId: phone.id, hostId: mac.id }, 400, "bad_request");
    await refusedWith({ viewerId: laptop.id }, 400, "bad_request");
    await refusedWith({ hostId: laptop.id }, 400, "bad_request");
    // Nothing changed: no prompt, no ticket, no end; the share is the only one listed.
    expect(await mac.user!.none((f) => f.type === "session.request")).toBe(true);
    expect(await phone.user!.none((f) => f.type === "session.ticket")).toBe(true);
    expect(await laptop.user!.none((f) => (f.type === "session.ended" || f.type === "session.revoked") && f.sessionId === sid)).toBe(true);
    expect((await list(laptop)).map((s) => [s.id, s.state])).toEqual([[sid, "approved"]]);
  });

  it("a joined machine moves a share it hosts, but never makes a device of its own machine the viewer", async () => {
    const person = await signIn();
    const box = await joinedMachine(person);
    // The cmux app on the same box: the same machine, another device.
    const boxApp = await device(person, "Box app", "linux", { machine: LINUX_BOX });
    const laptop = await device(person, "Laptop");
    const phone = await device(person, "Phone", "ios");
    const asked = await laptop.call("POST", "/v1/sessions", { hostId: box.id, scope: "view" });
    const sid = asked.json.session.id as string;
    const refused = await move(box, sid, { viewerId: boxApp.id });
    expect([refused.status, refused.json.error.code]).toEqual([403, "machine_scope"]);
    const res = await move(box, sid, { viewerId: phone.id });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(await ticketFor(phone, res.json.session.id)).toMatchObject({ role: "viewer", pushed: true, movedFrom: sid });
    // A share the machine is no part of is not its to move or list.
    const mac = await device(person, "Studio", "macos", { share: true });
    const other = await approvedSession(mac, laptop, "view");
    const notMine = await move(box, other.sid, { viewerId: phone.id });
    expect([notMine.status, notMine.json.error.code]).toEqual([403, "machine_scope"]);
    expect((await list(box)).map((s) => s.id)).toEqual([res.json.session.id]);
  });
});

describe("POST /v1/sessions with viewerId: the host pushes its screen", () => {
  it("a joined machine shares its screen to the person's Mac with no click on either side", async () => {
    const person = await signIn();
    const box = await joinedMachine(person);
    const laptop = await device(person, "Laptop");
    const res = await box.call("POST", "/v1/sessions", { hostId: box.id, viewerId: laptop.id, scope: "full" });
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json.session).toEqual({ id: expect.any(String), state: "approved", scope: "full", hostId: box.id, viewerId: laptop.id, movedFrom: null });
    const sid = res.json.session.id as string;
    expect(await ticketFor(laptop, sid)).toMatchObject({ role: "viewer", pushed: true, movedFrom: null, peer: { id: box.id } });
    expect(await ticketFor(box, sid)).toMatchObject({ role: "host", pushed: true, movedFrom: null, peer: { id: laptop.id } });
    expect(await box.user!.none((f) => f.type === "session.request")).toBe(true);
    // Without viewerId a machine session still cannot ask for a session as viewer.
    const mac = await device(person, "Studio", "macos", { share: true });
    const asViewer = await box.call("POST", "/v1/sessions", { hostId: mac.id, scope: "view" });
    expect([asViewer.status, asViewer.json.error.code]).toEqual([403, "machine_scope"]);
  });

  it("only the host pushes, never to its own machine, and never past a stored permission", async () => {
    const person = await signIn();
    const box = await joinedMachine(person);
    const boxApp = await device(person, "Box app", "linux", { machine: LINUX_BOX });
    const mac = await device(person, "Studio", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const push = (d: Device, hostId: string, viewerId: string, scope = "view") => d.call("POST", "/v1/sessions", { hostId, viewerId, scope });
    // The machine pushes another device's screen, or makes its own machine the viewer: refused.
    expect((await push(box, mac.id, laptop.id)).json.error.code).toBe("machine_scope");
    expect((await push(box, box.id, boxApp.id)).json.error.code).toBe("machine_scope");
    expect((await push(box, box.id, box.id)).json.error.code).toBe("bad_request");
    // A full-scope device pushes only its own machine's screen.
    expect((await push(laptop, mac.id, laptop.id)).json.error.code).toBe("not_host");
    // A stored Ask or View Only answer is never pushed past: no prompt, nothing created.
    await mac.call("PUT", `/v1/permissions/${mac.id}/${laptop.id}`, { scope: "view" });
    const needs = await push(mac, mac.id, laptop.id, "full");
    expect([needs.status, needs.json.error.code]).toEqual([409, "needs_approval"]);
    expect(await list(mac)).toEqual([]);
    expect(await laptop.user!.none((f) => f.type === "session.ticket")).toBe(true);
    // Within the permission it starts at once.
    const ok = await push(mac, mac.id, laptop.id, "view");
    expect(ok.json.session).toMatchObject({ state: "approved", hostId: mac.id, viewerId: laptop.id });
    expect(await ticketFor(laptop, ok.json.session.id)).toMatchObject({ pushed: true, movedFrom: null });
  });
});

describe("another account", () => {
  it("is never reachable: its devices are not found as viewer or host, and its sessions are not moved or listed", async () => {
    const person = await signIn();
    const mac = await device(person, "Studio", "macos", { share: true });
    const laptop = await device(person, "Laptop");
    const stranger = await signIn();
    const theirMac = await device(stranger, "Their Mac", "macos", { share: true });
    const theirPhone = await device(stranger, "Their Phone", "ios");
    const { sid } = await approvedSession(mac, laptop, "view");
    const notFound = (res: { status: number; json: any }) => expect([res.status, res.json.error.code]).toEqual([404, "not_found"]);
    notFound(await mac.call("POST", "/v1/sessions", { hostId: mac.id, viewerId: theirPhone.id, scope: "view" }));
    notFound(await move(laptop, sid, { viewerId: theirPhone.id }));
    notFound(await move(laptop, sid, { hostId: theirMac.id }));
    notFound(await move(theirPhone, sid, { viewerId: theirPhone.id }));
    expect(await list(theirPhone)).toEqual([]);
    expect((await list(laptop)).map((s) => s.id)).toEqual([sid]);
    expect(await theirPhone.user!.none((f) => f.type === "session.ticket")).toBe(true);
  });
});
