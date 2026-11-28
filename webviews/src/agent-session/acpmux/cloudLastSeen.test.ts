import { afterEach, describe, expect, test } from "bun:test";
import {
  CLOUD_TEAM_CHANGE_EVENT,
  cloudLastSeenFromReply,
  currentCloudLastSeenAt,
  followCloudTeamChange,
  freshCloudMachine,
  refreshCloudMachines,
  retryCloudMachines,
  setCloudMachinesForTest,
} from "./cloudMachines";

const AT = Date.UTC(2026, 9, 6, 9, 37, 0);
const machine = { id: "m-build", name: "build box", stage: "paused" };
const kept = { signedIn: true, loaded: true, complete: false, lastSeenAt: AT, machines: [machine] };
const fresh = { signedIn: true, loaded: true, machines: [machine] };

afterEach(() => setCloudMachinesForTest([]));

describe("cloudLastSeenFromReply", () => {
  test("reads a kept list's lastSeenAt", () => {
    expect(cloudLastSeenFromReply(kept)).toBe(AT);
  });

  test("a fresh reply, a signed-out or unloaded one, and a bad value carry none", () => {
    expect(cloudLastSeenFromReply(fresh)).toBeUndefined();
    expect(cloudLastSeenFromReply({ ...kept, signedIn: false })).toBeUndefined();
    expect(cloudLastSeenFromReply({ ...kept, loaded: false })).toBeUndefined();
    for (const lastSeenAt of [0, -5, Number.NaN, Number.POSITIVE_INFINITY, "1700000000000", null])
      expect(cloudLastSeenFromReply({ ...kept, lastSeenAt })).toBeUndefined();
    expect(cloudLastSeenFromReply(null)).toBeUndefined();
    expect(cloudLastSeenFromReply(undefined)).toBeUndefined();
  });
});

describe("the kept list's age", () => {
  test("a kept reply sets it; a fresh reply clears it", async () => {
    await refreshCloudMachines(async () => kept);
    expect(currentCloudLastSeenAt()).toBe(AT);
    await refreshCloudMachines(async () => fresh);
    expect(currentCloudLastSeenAt()).toBeUndefined();
  });

  test("a refused read clears it; no app to ask leaves it", async () => {
    await refreshCloudMachines(async () => kept);
    await refreshCloudMachines(async () => {
      throw { code: "native.not_connected" };
    });
    expect(currentCloudLastSeenAt()).toBe(AT);
    await refreshCloudMachines(async () => {
      throw new Error("refused");
    });
    expect(currentCloudLastSeenAt()).toBeUndefined();
  });

  test("a team change clears it", async () => {
    await refreshCloudMachines(async () => kept);
    const target = new EventTarget();
    let release: (value: unknown) => void = () => {};
    const stop = followCloudTeamChange(() => new Promise((resolve) => (release = resolve)), target);
    target.dispatchEvent(new Event(CLOUD_TEAM_CHANGE_EVENT));
    expect(currentCloudLastSeenAt()).toBeUndefined();
    release(fresh);
    await refreshCloudMachines(async () => fresh);
    expect(currentCloudLastSeenAt()).toBeUndefined();
    stop();
  });
});

describe("a pick of a kept Cloud row", () => {
  test("asks for a fresh read and acts on the machine as it lists it", async () => {
    await refreshCloudMachines(async () => kept);
    const asked: unknown[] = [];
    const picked = await freshCloudMachine(machine, async (_method, params) => {
      asked.push(params);
      return { ...fresh, machines: [{ ...machine, stage: "ready" }] };
    });
    expect(asked).toEqual([{ fresh: true }]);
    expect(picked).toEqual({ state: "fresh", machine: { ...machine, stage: "ready" } });
  });

  test("says unreachable while the list is still the kept one, gone once it no longer lists the machine", async () => {
    await refreshCloudMachines(async () => kept);
    expect(await freshCloudMachine(machine, async () => kept)).toEqual({ state: "unreachable" });
    expect(await freshCloudMachine(machine, async () => ({ ...fresh, machines: [] }))).toEqual({ state: "gone" });
  });
});

describe("Retry over the kept list", () => {
  test("waits for a fresh read, not the kept answer of a plain one", async () => {
    await refreshCloudMachines(async () => kept);
    const asked: unknown[] = [];
    let release: (value: unknown) => void = () => {};
    const retry = retryCloudMachines((_method, params) => {
      asked.push(params);
      return new Promise((resolve) => (release = resolve));
    });
    expect(asked).toEqual([{ fresh: true }]);
    expect(currentCloudLastSeenAt()).toBe(AT);
    release(fresh);
    await retry;
    expect(currentCloudLastSeenAt()).toBeUndefined();
  });
});
