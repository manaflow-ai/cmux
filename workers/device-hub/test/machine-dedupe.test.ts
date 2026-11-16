import { runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LEGACY_DUPLICATE_MS } from "../src/userDo";
import { Device, hubEnv, signIn, waitFor } from "./helpers";

// One machine, one record (Leo, Settings > Screen Sharing, 2026-11-15: the Mac he
// sat on listed twice, both Offline). Every cmux build (NIGHTLY, DEV, each tagged
// DEV) and every renewed identity registers its own device id with the same name.

const userStub = (userId: string) => hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));

type Account = Awaited<ReturnType<typeof signIn>>;

async function build(account: Account, name: string, machineId: string | null, platform: "macos" | "ios" = "macos") {
  const d = await Device.create(account, name, platform);
  d.machineId = machineId;
  await d.register();
  return d;
}

async function list(observer: Device): Promise<any[]> {
  const res = await observer.call("GET", "/v1/devices");
  expect(res.status, JSON.stringify(res.json)).toBe(200);
  return res.json.devices;
}

const ids = async (observer: Device) => (await list(observer)).map((d) => d.id).sort();

/**
 * The invariant (Detector, named in docs/handbook): no list an account's device
 * sees names one machine twice, and every list names the observer itself.
 */
async function expectOneRecordPerMachine(observers: Device[]) {
  for (const o of observers) {
    const devices = await list(o);
    const machines = devices.map((d) => d.machine).filter((m) => m !== null);
    expect(new Set(machines).size, `${o.name} ${o.id} lists one machine twice: ${JSON.stringify(devices)}`).toBe(machines.length);
    expect(devices.map((d) => d.id)).toContain(o.id);
  }
}

/** Moves the DOs' clock and has each `alive` device say so with a frame the User DO stamps with the moved clock. */
async function moveClockTo(at: number, account: Account, alive: Device[]) {
  vi.useFakeTimers({ toFake: ["Date"], now: at });
  for (const d of alive) {
    d.user!.send({ type: "here" });
    await waitFor(
      () =>
        runInDurableObject(userStub(account.userId), async (_i, s) => {
          const ws = s.getWebSockets(d.id).find((w) => !(w.deserializeAttachment() as { closed?: boolean } | null)?.closed);
          return ((ws?.deserializeAttachment() as { heardAt?: number } | null)?.heardAt ?? 0) as number;
        }),
      (heard) => heard >= at,
    );
  }
}

/** A fresh hub session for the same user under the moved clock (sessions outlive their Stack token by nothing). */
async function refreshSession(account: Account) {
  account.session = (await signIn(account.sub)).session;
}

afterEach(() => {
  vi.useRealTimers();
});

describe("one record per machine", () => {
  it("a second build of one Mac takes the first one's place, and the first comes back when it talks again", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    const nightly = await build(account, "cosmic-gray", "machine-cosmic-gray-0001");
    const dev = await build(account, "cosmic-gray", "machine-cosmic-gray-0001");
    expect(await ids(phone)).toEqual([phone.id, dev.id].sort());
    expect((await list(phone)).find((d) => d.id === dev.id).machine).toMatch(/^[0-9a-f]{32}$/);

    // NIGHTLY launches again: it is the Mac's record, DEV (offline) steps aside.
    expect((await nightly.call("GET", "/v1/me")).status).toBe(200);
    expect(await ids(phone)).toEqual([phone.id, nightly.id].sort());
    // Nothing was removed: DEV still signs in and is listed again when it talks.
    expect((await dev.call("GET", "/v1/me")).status).toBe(200);
    expect(await ids(phone)).toEqual([phone.id, dev.id].sort());
    await expectOneRecordPerMachine([phone, nightly, dev]);
  });

  it("never supersedes an online build; the list shows the machine once and each build sees itself", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    const nightly = await build(account, "cosmic-gray", "machine-cosmic-gray-0002");
    await nightly.connect();
    const dev = await build(account, "cosmic-gray", "machine-cosmic-gray-0002");
    await dev.connect();
    // Both are live records; the other devices see the Mac once, each build sees itself.
    expect((await list(phone)).filter((d) => d.name === "cosmic-gray")).toHaveLength(1);
    expect(await ids(nightly)).toEqual([phone.id, nightly.id].sort());
    expect(await ids(dev)).toEqual([phone.id, dev.id].sort());
    // DEV quits: the phone sees NIGHTLY, the one online.
    dev.user!.ws.close(1000, "quit");
    await waitFor(() => list(phone), (l) => l.some((d) => d.id === nightly.id && d.online));
    expect((await list(phone)).filter((d) => d.name === "cosmic-gray").map((d) => d.id)).toEqual([nightly.id]);
    await expectOneRecordPerMachine([phone, nightly]);
  });

  it("two Macs with one name are two devices when they send their machine ids", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    const a = await build(account, "Studio", "machine-studio-a-000001");
    const b = await build(account, "Studio", "machine-studio-b-000001");
    expect(await ids(phone)).toEqual([phone.id, a.id, b.id].sort());
    await expectOneRecordPerMachine([phone, a, b]);
  });

  it("the machine key is the account's own: one machine on two accounts gets unrelated keys, never the id sent", async () => {
    const one = await build(await signIn(), "Mac", "machine-shared-0000001");
    const two = await build(await signIn(), "Mac", "machine-shared-0000001");
    const k1 = (await one.call("GET", "/v1/me")).json.device.machine;
    const k2 = (await two.call("GET", "/v1/me")).json.device.machine;
    expect(k1).toMatch(/^[0-9a-f]{32}$/);
    expect(k2).toMatch(/^[0-9a-f]{32}$/);
    expect(k1).not.toBe(k2);
    expect(k1).not.toContain("machine-shared");
  });

  it("refuses a malformed machine id", async () => {
    const account = await signIn();
    const d = await Device.create(account);
    for (const machineId of ["short", "x".repeat(129), "has spaces in it ok?", 42]) {
      const res = await d.call("POST", "/v1/devices", { id: d.id, name: "Mac", platform: "macos", signingKey: d.signingKey, agreementKey: d.agreementKey, machineId });
      expect(res.status, String(machineId)).toBe(400);
    }
  });

  it("a build switch keeps the Mac's permissions, both as host and as viewer", async () => {
    const account = await signIn();
    const laptop = await build(account, "Laptop", "machine-laptop-000001");
    const nightly = await build(account, "Studio", "machine-studio-000003");
    expect((await nightly.call("PUT", `/v1/permissions/${nightly.id}/${laptop.id}`, { scope: "view" })).status).toBe(200);
    expect((await laptop.call("PUT", `/v1/permissions/${laptop.id}/${nightly.id}`, { scope: "full" })).status).toBe(200);
    const dev = await build(account, "Studio", "machine-studio-000003");
    const asHost = (await dev.call("GET", `/v1/permissions?host=${dev.id}`)).json.permissions;
    expect(asHost).toEqual([{ viewerId: laptop.id, scope: "view" }]);
    const asViewer = (await laptop.call("GET", `/v1/permissions?host=${laptop.id}`)).json.permissions;
    expect(asViewer).toEqual([{ viewerId: dev.id, scope: "full" }]);
  });

  it("cleans up records from before machine ids: same name and platform, offline past the threshold, never one online", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    // Leo's air-blue listed cosmic-gray three times: three builds, no machine id.
    const old1 = await build(account, "cosmic-gray", null);
    const old2 = await build(account, "Cosmic Gray", null);
    const live = await build(account, "cosmic-gray", null);
    await live.connect();
    await phone.connect();
    // Within the threshold nothing folds: a name alone is a weak hint.
    expect(await ids(phone)).toEqual([phone.id, old1.id, old2.id, live.id].sort());

    await moveClockTo(Date.now() + LEGACY_DUPLICATE_MS + 1000, account, [live, phone]);
    await refreshSession(account);
    expect(await ids(phone)).toEqual([phone.id, live.id].sort());
    // Another platform with the same name is another device.
    const ipad = await build(account, "cosmic-gray", null, "ios");
    expect(await ids(phone)).toEqual([phone.id, live.id, ipad.id].sort());
    // A legacy record that comes back is listed again; the next stale one steps aside then.
    expect((await old1.call("GET", "/v1/me")).status).toBe(200);
    expect(await ids(phone)).toContain(old1.id);
    expect(await ids(phone)).toContain(live.id);
  });

  it("a record from a newer build folds the same Mac's legacy records once they are stale", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    const legacy = await build(account, "cosmic-gray", null);
    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + LEGACY_DUPLICATE_MS + 1000 });
    await refreshSession(account);
    const current = await build(account, "cosmic-gray", "machine-cosmic-gray-0004");
    expect(await ids(phone)).toEqual([phone.id, current.id].sort());
    await expectOneRecordPerMachine([phone, current]);
  });

  it("Detector: one account never lists one machine twice, whatever its builds do", async () => {
    const account = await signIn();
    const phone = await build(account, "Phone", null, "ios");
    const machine = "machine-detector-00001";
    const builds: Device[] = [];
    for (let step = 0; step < 6; step++) {
      const b = await build(account, "Studio", machine);
      builds.push(b);
      if (step % 2 === 0) await b.connect();
      if (step % 3 === 0 && builds[0]!.user) builds[0]!.user.ws.close(1000, "quit");
      if (step === 4) expect((await builds[1]!.call("GET", "/v1/me")).status).toBe(200);
      await expectOneRecordPerMachine([phone, ...builds]);
    }
  });
});
