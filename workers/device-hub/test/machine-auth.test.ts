import { describe, expect, it } from "vitest";
import { platformUserIdFor } from "../src/machine";
import { BASE, Device, STACK_DEV_PROJECT, STACK_PROJECT, mockOutbound, platformCalls, platformMachines, rawCall, signIn, worker } from "./helpers";

/** A machine the person `sub` joined: its credential, as cmux-platform knows it. */
async function joinedMachine(sub: string, project = STACK_PROJECT, extra: Record<string, unknown> = {}) {
  const credential = `cmm_${crypto.randomUUID().replace(/-/g, "")}`;
  platformMachines.set(credential, {
    machineId: `machine_${crypto.randomUUID().slice(0, 8)}`,
    teamId: "team_01",
    userId: await platformUserIdFor(project, sub),
    expiresAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
    ...extra,
  });
  return credential;
}

async function machineSignIn(credential: string, deviceId: string) {
  mockOutbound();
  return rawCall("POST", "/v1/auth/machine", { body: { credential, deviceId } });
}

/** The machine's desktop, signed in with `credential` and registered: its device and session answer. */
async function machineHost(person: { userId: string }, credential: string) {
  const desktop = await Device.create({ userId: person.userId, session: "" }, "Desktop", "linux");
  const res = await machineSignIn(credential, desktop.id);
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  const machine = await Device.create({ userId: res.json.userId, session: res.json.session }, "Desktop", "linux");
  Object.assign(machine, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
  await machine.register();
  return { machine, answer: res.json };
}

/** `POST /v1/auth/device` signed by `d`: device-key renewal, with no credential. */
async function renew(d: Device) {
  const body = JSON.stringify({ userId: d.account.userId });
  const headers = { ...(await d.headers("POST", "/v1/auth/device", body)), "content-type": "application/json" };
  const res = await worker.fetch(`${BASE}/v1/auth/device`, { method: "POST", headers, body });
  const text = await res.text();
  return { status: res.status, json: text ? (JSON.parse(text) as any) : null };
}

/** A session token's claims. */
function claims(session: string): Record<string, any> {
  const part = (session.split(".")[1] ?? "").replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(part + "=".repeat((4 - (part.length % 4)) % 4)));
}

describe("POST /v1/auth/machine", () => {
  it("matches cmux-platform's user ids", async () => {
    // cmux-platform src/server/auth/Ids.ts: user_ + 20 hex of sha256("stack:<project>:<sub>").
    expect(await platformUserIdFor("p", "s")).toMatch(/^user_[0-9a-f]{20}$/);
    expect(await platformUserIdFor("p", "s")).toBe(await platformUserIdFor("p", "s"));
    expect(await platformUserIdFor("p", "s")).not.toBe(await platformUserIdFor("p", "t"));
  });

  it("signs a joined machine in as the person who joined it, and sets it up as a host", async () => {
    const person = await signIn();
    const credential = await joinedMachine(person.sub);
    const desktop = await Device.create({ userId: person.userId, session: "" }, "Desktop", "linux");
    const res = await machineSignIn(credential, desktop.id);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    expect(res.json).toMatchObject({ userId: person.userId, scope: "machine", ownerKind: "user", teamId: "team_01" });
    expect(res.json.machineId).toMatch(/^machine_/);
    expect(platformCalls).toContain(credential);
    const machine = await Device.create({ userId: person.userId, session: res.json.session }, "Desktop", "linux");
    Object.assign(machine, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
    await machine.register();
    const shared = await machine.call("PUT", `/v1/devices/${machine.id}/mac-screen`, { shared: true });
    expect(shared.status, JSON.stringify(shared.json)).toBe(200);
    // The person's own Mac sees it, shared: the same account, from the platform's answer alone.
    const mac = await Device.create(person, "Laptop", "macos");
    await mac.register();
    const listed = (await mac.call("GET", "/v1/devices")).json.devices.find((d: any) => d.id === machine.id);
    expect(listed).toMatchObject({ platform: "linux", macScreenShared: true });
  });

  it("serves only its own device, and nothing beyond setting it up and hosting", async () => {
    const person = await signIn();
    const credential = await joinedMachine(person.sub);
    const desktop = await Device.create({ userId: person.userId, session: "" }, "Desktop", "linux");
    const session = (await machineSignIn(credential, desktop.id)).json.session as string;
    const machine = await Device.create({ userId: person.userId, session }, "Desktop", "linux");
    // Another device's key under this session: refused before it registers anything.
    const other = await machine.call("POST", "/v1/devices", { id: machine.id, name: "x", platform: "linux", signingKey: machine.signingKey, agreementKey: machine.agreementKey });
    expect(other.status).toBe(403);
    Object.assign(machine, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
    await machine.register();
    // A full-scope change (relay writes) and another device's switch are refused.
    const relay = await machine.call("PUT", "/v1/relays/r1", { sealed: "x" });
    expect(relay.status).toBe(403);
    expect(relay.json.error?.code ?? relay.json.code).toBe("machine_scope");
    const mac = await Device.create(person, "Laptop", "macos");
    await mac.register();
    const theirs = await machine.call("PUT", `/v1/devices/${mac.id}/mac-screen`, { shared: true });
    expect(theirs.status).toBe(403);
  });

  it("trusts only cmux-platform's answer, never the machine", async () => {
    const person = await signIn();
    const deviceId = crypto.randomUUID();
    // A credential cmux-platform does not accept (unknown, or revoked: 401 there).
    expect((await machineSignIn("cmm_forged", deviceId)).status).toBe(401);
    // The body names no user: there is nothing a machine could claim.
    const res = await rawCall("POST", "/v1/auth/machine", { body: { credential: "cmm_forged", deviceId, userId: person.userId } });
    expect(res.status).toBe(401);
    // A join that names no person.
    const nobody = await joinedMachine(person.sub, STACK_PROJECT, { userId: undefined });
    expect((await machineSignIn(nobody, deviceId)).status).toBe(403);
    // An expired credential.
    const expired = await joinedMachine(person.sub, STACK_PROJECT, { expiresAt: new Date(Date.now() - 1000).toISOString() });
    expect((await machineSignIn(expired, deviceId)).status).toBe(401);
    // A bad device id or no credential.
    expect((await machineSignIn(await joinedMachine(person.sub), "not-a-uuid")).status).toBe(400);
    expect((await rawCall("POST", "/v1/auth/machine", { body: { deviceId } })).status).toBe(400);
  });

  it("joins no machine to a person the hub has never seen", async () => {
    // Joined to cmux, but never signed in to screen sharing: no hub account to join it to.
    const credential = await joinedMachine(`never-${crypto.randomUUID()}`);
    const res = await machineSignIn(credential, crypto.randomUUID());
    expect(res.status).toBe(403);
    expect(JSON.stringify(res.json)).toContain("account_not_on_hub");
  });

  it("keeps Stack projects apart", async () => {
    // Signed in on the dev project; the platform configured for prod names the same person
    // by its own project, so the dev account is not found through it.
    const dev = await signIn(undefined, STACK_DEV_PROJECT);
    const credential = await joinedMachine(dev.sub, STACK_DEV_PROJECT);
    expect((await machineSignIn(credential, crypto.randomUUID())).status).toBe(403);
  });

  it("ends no later than the machine credential and within the hour", async () => {
    const person = await signIn();
    const soon = Date.now() + 120_000;
    const credential = await joinedMachine(person.sub, STACK_PROJECT, { expiresAt: new Date(soon).toISOString() });
    const res = await machineSignIn(credential, crypto.randomUUID());
    expect(res.status).toBe(200);
    expect(res.json.expiresAt).toBeLessThanOrEqual(soon);
  });

  it("refuses a revoked or expired credential at once, and its last session ends within the hour", async () => {
    const person = await signIn();
    const credential = await joinedMachine(person.sub);
    const { machine, answer } = await machineHost(person, credential);
    const { iat, exp } = claims(answer.session);
    expect(exp - iat).toBeLessThanOrEqual(3600);
    // No anchor, so no device-key renewal: the session ends with its hour.
    const anchor = await machine.call("POST", "/v1/auth/device/anchor", {});
    expect(anchor.status).toBe(403);
    expect(JSON.stringify(anchor.json)).toContain("machine_scope");
    expect((await renew(machine)).status).toBe(403);
    // Renewal is a new sign-in, and cmux-platform is asked again: revoked there, refused here.
    const before = platformCalls.length;
    platformMachines.delete(credential);
    expect((await machineSignIn(credential, machine.id)).status).toBe(401);
    expect(platformCalls.length).toBe(before + 1);
    // Expired after it was issued: refused the same way.
    const lapsing = await joinedMachine(person.sub);
    await machineHost(person, lapsing);
    platformMachines.set(lapsing, { ...platformMachines.get(lapsing), expiresAt: new Date(Date.now() - 1000).toISOString() });
    expect((await machineSignIn(lapsing, crypto.randomUUID())).status).toBe(401);
  });

  it("drops an anchor the desktop kept from a person's sign-in once a machine session speaks for it", async () => {
    // The person enabled this desktop interactively: anchored, it renews by its device key.
    const person = await signIn();
    const desktop = await Device.create(person, "Desktop", "linux");
    await desktop.register();
    expect((await desktop.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);
    expect((await renew(desktop)).status).toBe(200);
    // The machine is joined and signs the same desktop in with its credential.
    const credential = await joinedMachine(person.sub);
    const res = await machineSignIn(credential, desktop.id);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const machine = await Device.create({ userId: person.userId, session: res.json.session }, "Desktop", "linux");
    Object.assign(machine, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
    await machine.register();
    // The old anchor is gone: a revoked credential cannot be outlived by device-key renewal.
    expect((await renew(desktop)).status).toBe(403);
    // A machine call on an already-registered desktop drops one too.
    const again = await Device.create(person, "Desktop 2", "linux");
    await again.register();
    expect((await again.call("POST", "/v1/auth/device/anchor", {})).status).toBe(200);
    const second = await machineSignIn(await joinedMachine(person.sub), again.id);
    const host = await Device.create({ userId: person.userId, session: second.json.session }, "Desktop 2", "linux");
    Object.assign(host, { id: again.id, signing: again.signing, signingKey: again.signingKey, agreementKey: again.agreementKey });
    expect((await host.call("PUT", `/v1/devices/${again.id}/mac-screen`, { shared: true })).status).toBe(200);
    expect((await renew(again)).status).toBe(403);
  });

  it("never makes one team's machine read as another team's person", async () => {
    // Two people on two teams; A joined a machine to team A.
    const a = await signIn();
    const b = await signIn();
    const credential = await joinedMachine(a.sub, STACK_PROJECT, { teamId: "team_A" });
    const { machine, answer } = await machineHost(a, credential);
    expect(answer).toMatchObject({ userId: a.userId, teamId: "team_A", ownerKind: "user" });
    expect(answer.userId).not.toBe(b.userId);
    // B's own devices: the machine is not among them, so it is not B's same-account host.
    const bMac = await Device.create(b, "Laptop", "macos");
    await bMac.register();
    const listed = (await bMac.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id);
    expect(listed).not.toContain(machine.id);
    // And the machine's session reaches nothing of B's.
    expect((await machine.call("PUT", `/v1/devices/${bMac.id}/mac-screen`, { shared: true })).status).toBe(403);
    // A team answer never names the account: a credential on team B joined by A is still A's.
    const onB = await joinedMachine(a.sub, STACK_PROJECT, { teamId: "team_B" });
    const other = await machineSignIn(onB, crypto.randomUUID());
    expect(other.json).toMatchObject({ userId: a.userId, teamId: "team_B" });
  });
});

describe("a joined machine and another account", () => {
  // Leo, 2026-11-16: "you shouldn't need permissions on it... you just ask it on the machine that you
  // initiated on". The joining account's own devices reach its machine with nothing done there; that is
  // safe because no other account can: each account's devices live in its own UserDO.
  it("gives a second account's viewer no device and no session for the first account's machine", async () => {
    const a = await signIn();
    const b = await signIn();
    const credential = await joinedMachine(a.sub);
    const { machine } = await machineHost(a, credential);
    await machine.share(true);
    const host = await machine.connect();

    const guest = await Device.create(b, "Guest", "linux");
    await guest.register();
    const listed = (await guest.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id);
    expect(listed).not.toContain(machine.id);
    for (const scope of ["view", "full"] as const) {
      const asked = await guest.call("POST", "/v1/sessions", { hostId: machine.id, scope });
      expect([asked.status, asked.json.error.code]).toEqual([404, "not_found"]);
    }
    expect(await host.none((f) => typeof f.type === "string" && f.type.startsWith("session."))).toBe(true);

    // The joining account's own viewer does reach it: the refusal above is the account, not the machine.
    const own = await Device.create(a, "Laptop", "macos");
    await own.register();
    expect((await own.call("GET", "/v1/devices")).json.devices.map((d: any) => d.id)).toContain(machine.id);
    const mine = await own.call("POST", "/v1/sessions", { hostId: machine.id, scope: "view" });
    expect(mine.status, JSON.stringify(mine.json)).toBe(200);
  });
});
