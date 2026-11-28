import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Device, hubEnv, signIn } from "./helpers";

const userStub = (userId: string) => hubEnv.USER_DO.get(hubEnv.USER_DO.idFromName(userId));

/** Each listed device's kind, by name, as another device of the account reads them. */
async function kinds(reader: Device): Promise<Record<string, string | null>> {
  const res = await reader.call("GET", "/v1/devices");
  expect(res.status).toBe(200);
  return Object.fromEntries((res.json.devices as { name: string; kind: string | null }[]).map((d) => [d.name, d.kind]));
}

// Leo, 2026-11-14: "nicer icons ... across all the remote related areas". Screen Sharing and the
// iPhone draw each device by what it is, so the hub keeps the kind each app reports.
describe("device kind", () => {
  it("stores the kind a device registers with and lists it to the other devices", async () => {
    const account = await signIn();
    const laptop = await Device.create(account, "Laptop", "macos");
    const mini = await Device.create(account, "Mini", "macos");
    const phone = await Device.create(account, "Phone", "ios");
    expect((await laptop.register({ kind: "macbook" })).json.device.kind).toBe("macbook");
    await mini.register({ kind: "mac-mini" });
    await phone.register({ kind: "iphone" });
    expect(await kinds(phone)).toEqual({ Laptop: "macbook", Mini: "mac-mini", Phone: "iphone" });
    expect((await mini.call("GET", "/v1/me")).json.device.kind).toBe("mac-mini");
  });

  it("reads a device that never said its kind as unknown (null)", async () => {
    const account = await signIn();
    const old = await Device.create(account, "Old app", "macos");
    const reg = await old.register();
    expect(reg.json.device).toHaveProperty("kind", null);
    expect(await kinds(old)).toEqual({ "Old app": null });
  });

  it("keeps the stored kind when a register leaves it out, and takes a new one", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Mac", "macos");
    await d.register({ kind: "mac-studio" });
    // The screen-sharing helper registers the same device without a kind.
    expect((await d.register()).json.device.kind).toBe("mac-studio");
    expect((await d.register({ kind: null })).json.device.kind).toBe("mac-studio");
    expect((await d.register({ kind: "mac-pro" })).json.device.kind).toBe("mac-pro");
  });

  it("keeps a newer app's kind name, registers past a malformed one, and refuses a kind that is not a string", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Mac", "macos");
    expect((await d.register({ kind: "vision-pro" })).json.device.kind).toBe("vision-pro");
    // A string that is no wire name is no kind: the registration goes through and keeps the stored one.
    for (const kind of ["", "MacBook", "mac mini", "-mini", "mac--mini", "mac_mini", "a".repeat(33)]) {
      expect((await d.register({ kind })).json.device.kind, JSON.stringify(kind)).toBe("vision-pro");
    }
    const body = { id: d.id, name: "Mac", platform: "macos", signingKey: d.signingKey, agreementKey: d.agreementKey };
    for (const kind of [3, true, ["macbook"], { kind: "macbook" }]) {
      const res = await d.call("POST", "/v1/devices", { ...body, kind });
      expect([res.status, res.json.error.code], JSON.stringify(kind)).toEqual([400, "bad_request"]);
    }
    expect((await d.call("GET", "/v1/me")).json.device.kind).toBe("vision-pro");
  });

  it("adds the column to a User DO from before it: its rows read as unknown, then take a kind", async () => {
    const account = await signIn();
    const d = await Device.create(account, "Mac", "macos");
    await d.register({ kind: "macbook" });
    const stub = userStub(account.userId);
    // The User DO as it was before the column: its devices table has no `kind`.
    await runInDurableObject(stub, (_i, s) => {
      s.storage.sql.exec("ALTER TABLE devices DROP COLUMN kind");
    });
    await evictDurableObject(stub);
    // The next wake adds the column in place; the old row has no kind.
    expect(await kinds(d)).toEqual({ Mac: null });
    const columns = await runInDurableObject(stub, (_i, s) => s.storage.sql.exec("PRAGMA table_info(devices)").toArray().map((c) => c.name));
    expect(columns).toContain("kind");
    expect((await d.register({ kind: "macbook" })).json.device.kind).toBe("macbook");
  });
});
