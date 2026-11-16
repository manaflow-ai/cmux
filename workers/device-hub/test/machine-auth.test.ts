import { describe, expect, it } from "vitest";
import { platformUserIdFor } from "../src/machine";
import { Device, STACK_DEV_PROJECT, STACK_PROJECT, mockOutbound, platformCalls, platformMachines, rawCall, signIn } from "./helpers";

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
    expect(res.json).toMatchObject({ userId: person.userId, scope: "machine" });
    expect(platformCalls).toContain(credential);
    const machine = await Device.create({ userId: person.userId, session: res.json.session }, "Desktop", "linux");
    Object.assign(machine, { id: desktop.id, signing: desktop.signing, signingKey: desktop.signingKey, agreementKey: desktop.agreementKey });
    await machine.register();
    const anchored = await machine.call("POST", "/v1/auth/device/anchor", {});
    expect(anchored.status, JSON.stringify(anchored.json)).toBe(200);
    expect(anchored.json.anchoredUntil).toBeGreaterThan(Date.now());
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
});
