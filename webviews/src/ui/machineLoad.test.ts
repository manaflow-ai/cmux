// ui/machineLoad.ts: acpmux's `peers[].load` read and worded the same for every list of machines
// (the composer's machine picker and Settings > Machines), so both show the same numbers.
import { expect, test } from "bun:test";
import { freeGB, machineLoadOf, machineLoadsFromStatus, machineLoadText, type MachineLoadSay } from "./machineLoad";
import { busyLoad, idleLoad, offlineLoad } from "./machineLoad.fixtures";

/** English words with every placeholder filled, as both catalogs say them. */
const say: MachineLoadSay = (key, values = {}) => {
  const words: Record<string, string> = {
    cores: "{busy}/{cores} cores busy",
    free: "{free} GB free",
    chat: "1 chat",
    chats: "{n} chats",
    room: "room for {n}",
    offlineFor: "offline {ago}",
    minutes: "{n} min",
    hours: "{n} h",
    days: "{n} d",
    unknown: "no reading",
  };
  return (words[key] ?? key).replace(/\{(\w+)\}/g, (_, name: string) => String(values[name]));
};

test("a status reply's peers each give their load row by name; a peer without one gives none", () => {
  const loads = machineLoadsFromStatus({
    peers: [
      { name: "gcp-3", load: { ...idleLoad, extra: "dropped" } },
      { name: "old", load: { verdict: "maybe" } },
      { name: "older" },
      { load: idleLoad },
    ],
  });
  expect(Object.keys(loads)).toEqual(["gcp-3"]);
  expect(loads["gcp-3"]).toEqual(idleLoad);
  expect(machineLoadsFromStatus(null)).toEqual({});
});

test("a number that is not finite and non-negative reads as no reading, never 0", () => {
  const load = machineLoadOf({ verdict: "room", room: -1, coresBusy: "3", cores: Infinity, live: null });
  expect(load).toMatchObject({ room: null, coresBusy: null, cores: null, live: null, words: "room" });
});

test("idle, busy and offline read as the picker and Settings show them", () => {
  expect(machineLoadText(idleLoad, say)).toEqual({
    facts: ["1.4/16 cores busy", "24 GB free", "1 chat"],
    verdict: "room for 5",
  });
  expect(machineLoadText(busyLoad, say)).toEqual({
    facts: ["12/12 cores busy", "2.4 GB free", "6 chats"],
    verdict: "busy",
  });
  // A machine that is not up shows no numbers, only how long it has been gone.
  expect(machineLoadText(offlineLoad, say)).toEqual({ facts: [], verdict: "offline 2 min" });
  expect(machineLoadText({ ...offlineLoad, offlineMs: 30_000 }, say).verdict).toBe("offline");
  expect(machineLoadText({ ...offlineLoad, offlineMs: 3 * 3_600_000 }, say).verdict).toBe("offline 3 h");
  expect(machineLoadText({ ...offlineLoad, offlineMs: 2 * 86_400_000 }, say).verdict).toBe("offline 2 d");
  expect(machineLoadText({ ...idleLoad, verdict: "unknown", coresBusy: null }, say).verdict).toBe("no reading");
});

test("free RAM is whole from 10 GB, one decimal under", () => {
  expect([freeGB(24.4e9), freeGB(9.96e9), freeGB(2.44e9)]).toEqual(["24", "10", "2.4"]);
});
