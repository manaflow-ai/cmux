// The machine card's model (machineCardModel.ts): it says only what the page has, never a zero for
// a number it does not have, and shows no usage for a machine that is not awake.
import { describe, expect, test } from "bun:test";
import { cloudMachinesFromReply, cloudMachineSize } from "./cloudMachines";
import { machineCard, machineCardDot, machineCardSpecs, machineCardStatus } from "./machineCardModel";

const size = { cpu: 4, memoryMb: 16384, diskMb: 65536 };
const reading = { ramFreeGB: 12.9, load1: 0.4, coresBusy: 0, cores: 4, busy: false, lowMemory: false };

describe("machine card status", () => {
  test("the account's stage says it; acpmux's link only when there is no record", () => {
    expect(machineCardStatus({ stage: "ready" }, false)).toBe("awake");
    expect(machineCardStatus({ stage: "paused" }, false)).toBe("paused");
    for (const stage of ["requesting", "creating", "booting", "connecting", "resuming"])
      expect(machineCardStatus({ stage }, false)).toBe("starting");
    expect(machineCardStatus({ stage: "failed" }, undefined)).toBe("failed");
    // A machine acpmux is linked to is up, whatever an older list says.
    expect(machineCardStatus({ stage: "unknown" }, true)).toBe("awake");
    expect(machineCardStatus(undefined, true)).toBe("awake");
    expect(machineCardStatus(undefined, false)).toBeUndefined();
    expect(machineCardStatus(undefined, undefined)).toBeUndefined();
  });

  test("the chip's dot: filled awake, a grey dot asleep, the spinner waking, a ring failed", () => {
    expect(machineCardDot("awake")).toEqual({ live: true });
    expect(machineCardDot("paused")).toEqual({ live: false, sleep: "paused" });
    expect(machineCardDot("starting")).toEqual({ live: false, sleep: "resuming" });
    expect(machineCardDot("failed")).toEqual({ live: false });
    expect(machineCardDot(undefined)).toBeUndefined();
  });
});

describe("machine card size", () => {
  test("the record's size in GB, as much as it says", () => {
    expect(machineCardSpecs(size)).toEqual({ cpu: 4, memoryGB: 16, diskGB: 64 });
    expect(machineCardSpecs({ memoryMb: 4096 })).toEqual({ memoryGB: 4 });
    expect(machineCardSpecs({})).toBeUndefined();
    expect(machineCardSpecs(undefined)).toBeUndefined();
  });

  test("the list row's size keeps only positive whole numbers", () => {
    expect(cloudMachineSize({ cpu: 4, memoryMb: 16384, diskMb: 65536 })).toEqual(size);
    expect(cloudMachineSize({ cpu: 0, memoryMb: -1, diskMb: 1.5 })).toBeUndefined();
    expect(cloudMachineSize({ cpu: "4" })).toBeUndefined();
    expect(cloudMachineSize(null)).toBeUndefined();
    expect(cloudMachineSize([4])).toBeUndefined();
    const [row] = cloudMachinesFromReply({
      signedIn: true,
      loaded: true,
      machines: [{ id: "vm-1", name: "box", stage: "ready", size: { cpu: 2, extra: 9 } }],
    });
    expect(row).toEqual({ id: "vm-1", name: "box", stage: "ready", size: { cpu: 2 } });
    const [bare] = cloudMachinesFromReply({
      signedIn: true,
      loaded: true,
      machines: [{ id: "a", name: "b", stage: "ready" }],
    });
    expect(bare).toEqual({ id: "a", name: "b", stage: "ready" });
  });
});

describe("machine card usage", () => {
  test("awake and read: load against cores, free memory against the machine's size", () => {
    const card = machineCard({
      name: "box",
      machine: { id: "vm", name: "box", stage: "ready", size },
      resources: reading,
    });
    expect(card.status).toBe("awake");
    expect(card.specs).toEqual({ cpu: 4, memoryGB: 16, diskGB: 64 });
    expect(card.usage.kind).toBe("readings");
    if (card.usage.kind !== "readings") return;
    expect(card.usage.load).toEqual({ load: 0.4, cores: 4, fraction: 0.1 });
    // 12.9 decimal GB free is 12 GB in the size's binary GB.
    expect(card.usage.memory?.freeGB).toBe(12);
    expect(card.usage.memory?.totalGB).toBe(16);
    expect(card.usage.memory?.fraction).toBeCloseTo(0.25, 2);
  });

  test("a load past the cores fills the bar and says how far past", () => {
    const card = machineCard({ name: "box", connected: true, resources: { ...reading, load1: 9.5, cores: 4 } });
    expect(card.usage.kind === "readings" && card.usage.load).toEqual({ load: 9.5, cores: 4, fraction: 1 });
  });

  test("with no size, the free memory alone and no bar", () => {
    const card = machineCard({ name: "box", connected: true, resources: reading });
    expect(card.specs).toBeUndefined();
    expect(card.usage.kind === "readings" && card.usage.memory).toEqual({ freeGB: 12 });
  });

  test("a reading made without the load to one decimal uses the rounded cores busy", () => {
    const { load1: _, ...older } = reading;
    const card = machineCard({ name: "box", connected: true, resources: { ...older, coresBusy: 3 } });
    expect(card.usage.kind === "readings" && card.usage.load?.load).toBe(3);
  });

  test("awake with no reading yet says so; asleep, waking or failed shows no usage at all", () => {
    expect(machineCard({ name: "box", connected: true }).usage).toEqual({ kind: "unread" });
    for (const stage of ["paused", "booting", "failed"]) {
      const card = machineCard({ name: "box", machine: { id: "vm", name: "box", stage, size }, resources: reading });
      expect(card.usage).toEqual({ kind: "asleep" });
      expect(card.specs).toEqual({ cpu: 4, memoryGB: 16, diskGB: 64 });
    }
  });

  test("a machine nothing says anything of has no status and no usage", () => {
    expect(machineCard({ name: "box" })).toEqual({ name: "box", usage: { kind: "asleep" } });
  });
});
