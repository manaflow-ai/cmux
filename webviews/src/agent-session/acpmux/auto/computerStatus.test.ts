import { expect, test } from "bun:test";
import { translate } from "../i18n";
import {
  computerStatusOf,
  elapsedSeconds,
  sizeRow,
  sleepRow,
  statusChipText,
  statusLine,
  statusTicks,
  whyRow,
  type ComputerStatus,
} from "./computerStatus";

const t: typeof translate = (key, values) => translate(key, values, "en");
const base: ComputerStatus = {
  session_id: "s1",
  home: "cloud",
  phase: "running",
  size: { mode: "auto" },
  sleep: { mode: "auto" },
};
const at = (ms: number) => `t${ms}`;
const NOW = 100_000;

test("a chat that simply runs has no status line", () => {
  expect(statusLine(base, NOW, t)).toBeUndefined();
});

test("preparing and moving count whole seconds", () => {
  expect(statusLine({ ...base, phase: "preparing", phase_since_ms: NOW - 3400 }, NOW, t)).toEqual({
    text: "Preparing cloud computer… 3 s",
    actions: [],
  });
  const moving = {
    ...base,
    phase: "moving" as const,
    phase_since_ms: NOW - 6000,
    move: { direction: "to_cloud" as const, cancellable: true },
  };
  expect(statusLine(moving, NOW, t)).toEqual({
    text: "Moving to Cloud… 6 s",
    actions: [{ id: "cancel", label: "Cancel" }],
  });
  expect(statusLine({ ...moving, move: { direction: "to_mac", cancellable: false } }, NOW, t)).toEqual({
    text: "Moving to This Mac… 6 s",
    actions: [],
  });
  expect(elapsedSeconds({ ...base, phase_since_ms: NOW + 5000 }, NOW)).toBe(0);
  expect(elapsedSeconds(base, NOW)).toBe(0);
});

test("a move that did not finish says why and where the chat still is", () => {
  const failed: ComputerStatus = {
    ...base,
    home: "this_mac",
    phase: "move_failed",
    move: { direction: "to_cloud", cancellable: false, failure: "network_dropped" },
  };
  expect(statusLine(failed, NOW, t)).toEqual({
    text: "Move didn't finish · Your network dropped · Still on This Mac",
    actions: [{ id: "retry", label: "Retry" }],
  });
  expect(statusLine({ ...failed, move: undefined }, NOW, t)?.text).toBe("Move didn't finish · Still on This Mac");
});

test("sleeping, reconnecting, paused and slots full", () => {
  expect(statusLine({ ...base, phase: "sleeping" }, NOW, t)).toEqual({ text: "Sleeping", actions: [] });
  expect(statusLine({ ...base, phase: "reconnecting" }, NOW, t)?.text).toBe("Reconnecting to Cloud…");
  expect(statusLine({ ...base, phase: "paused_spend_cap" }, NOW, t)).toEqual({
    text: "Paused at your overage limit",
    actions: [
      { id: "raise_limit", label: "Raise limit" },
      { id: "run_on_mac", label: "Run on This Mac" },
    ],
  });
  expect(statusLine({ ...base, phase: "paused_pool_spent" }, NOW, t)?.actions.map((a) => a.id)).toEqual([
    "upgrade",
    "run_on_mac",
  ]);
  const full = statusLine({ ...base, home: "this_mac", phase: "staying_local_slots_full" }, NOW, t);
  expect(full?.text).toBe("Staying on This Mac: all your Cloud slots are busy");
  expect(full?.actions.map((a) => a.label)).toEqual(["Pause one", "Upgrade"]);
  expect(statusChipText({ text: "Move didn't finish · Retry", actions: [] })).toBe("Move didn't finish");
});

test("the Size row shows a size only once there is a cloud computer", () => {
  expect(sizeRow(base, t)).toEqual({ auto: true, pinned: false });
  expect(sizeRow({ ...base, shape: { vcpu: 2, memory_gib: 4 } }, t)).toEqual({
    auto: true,
    pinned: false,
    note: "now 2 vCPU · 4 GB, grows as it works",
  });
  expect(sizeRow({ ...base, size: { mode: "pinned", vcpu: 8, memory_gib: 16 } }, t)).toEqual({
    auto: false,
    pinned: true,
    note: "pinned at 8 vCPU · 16 GB",
  });
});

test("the Sleep row", () => {
  expect(sleepRow(base, t, at)).toEqual({ mode: "auto", note: "sleeps while it waits on the model or you" });
  expect(sleepRow({ ...base, sleep: { mode: "keep_awake", until_ms: 5 } }, t, at).note).toBe("awake until t5");
  expect(sleepRow({ ...base, sleep: { mode: "keep_awake" } }, t, at).note).toBe("awake until you say");
});

test("the Why row is one sentence per reason", () => {
  const why = (reason: NonNullable<ComputerStatus["why"]>["reason"], command?: string) =>
    whyRow({ ...base, why: { at_ms: 7, reason, ...(command ? { command } : {}) } }, t, at);
  expect(whyRow(base, t, at)).toBeUndefined();
  expect(why("mac_memory_pressure")).toBe("Moved to Cloud at t7: your Mac was under memory pressure.");
  expect(why("mac_busy")).toBe("Moved to Cloud at t7: your Mac was busy.");
  expect(why("lid_closed")).toBe("Moved to Cloud at t7: you closed the lid.");
  expect(why("grew_for_memory", "cargo build")).toBe("Grew at t7: cargo build needed more memory.");
  expect(why("grew_for_memory")).toBe("Grew at t7: it needed more memory.");
  expect(why("person_moved")).toBe("You moved it to Cloud at t7.");
  expect(why("slots_full")).toBe("Staying on This Mac since t7: all your Cloud slots are busy.");
  expect(why("spend_cap")).toBe("Paused at t7: you reached your overage limit.");
});

test("place.status reads as Rust sends it, and a half-written one is none", () => {
  const sent = {
    session_id: "s1",
    home: "this_mac",
    phase: "moving",
    phase_since_ms: 1_700_000_000_000,
    move: { direction: "to_cloud", cancellable: true },
    size: { mode: "auto" },
    sleep: { mode: "auto" },
    why: { at_ms: 1_700_000_000_000, reason: "mac_memory_pressure" },
  };
  expect(computerStatusOf(sent)).toEqual(sent as ComputerStatus);
  expect(statusTicks(computerStatusOf(sent)!)).toBe(true);
  // A phase this page has no words for (Rust's `paused`), a missing session or home: no status, no line.
  expect(computerStatusOf({ ...sent, phase: "paused" })).toBeUndefined();
  expect(computerStatusOf({ ...sent, session_id: "" })).toBeUndefined();
  expect(computerStatusOf({ ...sent, home: "mars" })).toBeUndefined();
  expect(computerStatusOf("moving")).toBeUndefined();
  // Rows the app left out read as Auto; a stray failure or reason word is dropped.
  const loose = computerStatusOf({
    session_id: "s1",
    home: "cloud",
    phase: "move_failed",
    move: { direction: "to_mac", cancellable: false, failure: "gremlins" },
    why: { at_ms: 5, reason: "gremlins" },
  });
  expect(loose).toEqual({
    session_id: "s1",
    home: "cloud",
    phase: "move_failed",
    move: { direction: "to_mac", cancellable: false },
    size: { mode: "auto" },
    sleep: { mode: "auto" },
  });
  expect(statusTicks(loose!)).toBe(false);
});
