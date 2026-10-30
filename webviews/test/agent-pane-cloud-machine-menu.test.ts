// l10n-allow-file: test fixture machine names, not shipped UI.
//
// Pause and Resume for a chat's Cloud machine in the chat menu (cloudMachineMenu.ts,
// cmuxterm-hq#4755): the chat's peer names one of the account's machines (any case); a running
// machine offers Pause, stopping a running turn first and saying so; a paused one offers Resume;
// one starting, failed or not the account's offers nothing. A pick runs one native call (the app
// checks the click) and reads the account's list again, whatever the app answered. Stop and
// Pause pauses only once the turn has ended; the list is read until the machine's stage moves.
import { expect, test } from "bun:test";
import { chatCloudMachine, cloudMachineRows, createStopWaiter } from "../src/agent-session/acpmux/cloudMachineMenu";
import {
  ACTION_READS_MS,
  readUntilMoved,
  setCloudMachinesForTest,
  type CloudMachine,
} from "../src/agent-session/acpmux/cloudMachines";
import type { ChatMenuItem } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { translate as t } from "../src/agent-session/acpmux/i18n";

const machines: CloudMachine[] = [
  { id: "vm_run", name: "Dev-VM-2", stage: "ready" },
  { id: "vm_paused", name: "build box", stage: "paused" },
  { id: "vm_boot", name: "fresh", stage: "booting" },
];

test("a Cloud chat's machine is the account's machine of its peer name, any case", () => {
  expect(chatCloudMachine({ hostKind: "cloud", peer: "dev-vm-2" }, machines)?.id).toBe("vm_run");
  expect(chatCloudMachine({ hostKind: "cloud", host: "BUILD BOX" }, machines)?.id).toBe("vm_paused");
  expect(chatCloudMachine({ hostKind: "ssh", peer: "dev-vm-2" }, machines)).toBeUndefined();
  expect(chatCloudMachine({ hostKind: "local", host: "This Mac" }, machines)).toBeUndefined();
  expect(chatCloudMachine({ hostKind: "cloud", peer: "elsewhere" }, machines)).toBeUndefined();
  expect(chatCloudMachine(undefined, machines)).toBeUndefined();
  // Two machines of that name: neither, so a pick never lands on the other one.
  const twins = [...machines, { id: "vm_twin", name: "dev-vm-2", stage: "ready" }];
  expect(chatCloudMachine({ hostKind: "cloud", peer: "dev-vm-2" }, twins)).toBeUndefined();
  // A peer name the account does not have still lets the host's name match.
  expect(chatCloudMachine({ hostKind: "cloud", peer: "stale", host: "build box" }, machines)?.id).toBe("vm_paused");
  // Peer and host naming two different machines: neither.
  expect(chatCloudMachine({ hostKind: "cloud", peer: "dev-vm-2", host: "build box" }, machines)).toBeUndefined();
  // Both naming the same machine: that one.
  expect(chatCloudMachine({ hostKind: "cloud", peer: "dev-vm-2", host: "DEV-VM-2" }, machines)?.id).toBe("vm_run");
});

function rows(
  machine: CloudMachine | undefined,
  working: boolean,
  stops = true,
  state: { session: string | undefined; running: boolean } = { session: "s1", running: working },
) {
  const calls: [string, unknown][] = [];
  let reads = 0;
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "cloudMachine.pause" && params?.id === "vm_refused") throw new Error("gesture");
    return {};
  };
  const items = cloudMachineRows(
    machine,
    working,
    t,
    call,
    () => (reads += 1),
    () => ({ ...state }),
    async (session) => {
      calls.push(["(turn ended?)", session]);
      // A stop that took: the chat's turn no longer runs.
      if (stops) state.running = false;
      return stops;
    },
    "s1",
  );
  const pick = async (index = 0) => {
    const item = items[index] as Exclude<ChatMenuItem, "separator">;
    item.onSelect!();
    await new Promise((resolve) => setImmediate(resolve));
  };
  return { items, calls, pick, reads: () => reads, state };
}

const label = (item: ChatMenuItem | undefined) => (item && item !== "separator" ? item.label : undefined);

test("a running machine offers Pause, which pauses it and reads the list again", async () => {
  const r = rows(machines[0], false);
  expect(r.items.map(label)).toEqual([t("chatMenu.pauseMachine")]);
  await r.pick();
  expect(r.calls).toEqual([["cloudMachine.pause", { id: "vm_run" }]]);
  expect(r.reads()).toBe(1);
});

test("while the chat's turn runs, Pause says it stops the turn and stops it first", async () => {
  const r = rows(machines[0], true);
  expect(r.items.map(label)).toEqual([t("chatMenu.stopAndPauseMachine")]);
  await r.pick();
  expect(r.calls).toEqual([
    ["chat.cancel", undefined],
    ["(turn ended?)", "s1"],
    ["cloudMachine.pause", { id: "vm_run" }],
  ]);
});

test("the pick reads the chat's turn when it runs, not when the menu was drawn", async () => {
  // Drawn while idle; a turn began before the click: it is stopped first all the same.
  const r = rows(machines[0], false, true, { session: "s1", running: true });
  await r.pick();
  expect(r.calls.map(([method]) => method)).toEqual(["chat.cancel", "(turn ended?)", "cloudMachine.pause"]);
});

test("a turn that starts again in the chat after the stop is not frozen", async () => {
  const state = { session: "s1" as string | undefined, running: true };
  const calls: string[] = [];
  const items = cloudMachineRows(
    machines[0],
    true,
    t,
    async (method) => void calls.push(method),
    () => undefined,
    () => ({ ...state }),
    async () => {
      // The turn stopped; a queued prompt started the next one before the pause.
      state.running = true;
      return true;
    },
    "s1",
  );
  (items[0] as Exclude<ChatMenuItem, "separator">).onSelect!();
  await new Promise((resolve) => setImmediate(resolve));
  expect(calls).toEqual(["chat.cancel"]);
});

test("a Pause picked once the pane shows another chat stops nothing and pauses nothing", async () => {
  // Drawn for s1; the pane moved to s2 before the click.
  const r = rows(machines[0], true, true, { session: "s2", running: true });
  await r.pick();
  expect(r.calls).toEqual([]);
  expect(r.reads()).toBe(1);
});

test("a pick with no chat shown pauses nothing, and still resumes", async () => {
  const r = rows(machines[0], false, true, { session: undefined, running: false });
  await r.pick();
  expect(r.calls).toEqual([]);
  const resume = rows(machines[1], false, true, { session: undefined, running: false });
  await resume.pick();
  expect(resume.calls).toEqual([["cloudMachine.resume", { id: "vm_paused" }]]);
});

test("a pick for a chat the pane has left pauses nothing", async () => {
  const state = { session: "s1" as string | undefined, running: true };
  const calls: string[] = [];
  let reads = 0;
  const items = cloudMachineRows(
    machines[0],
    true,
    t,
    async (method) => void calls.push(method),
    () => (reads += 1),
    () => ({ ...state }),
    async () => {
      // While the stop is awaited, the pane moves to another chat.
      state.session = "s2";
      return true;
    },
    "s1",
  );
  (items[0] as Exclude<ChatMenuItem, "separator">).onSelect!();
  await new Promise((resolve) => setImmediate(resolve));
  expect(calls).toEqual(["chat.cancel"]);
  expect(reads).toBe(1);
});

test("a turn that has not stopped is not frozen: no pause, and the list is read again", async () => {
  const r = rows(machines[0], true, false);
  await r.pick();
  expect(r.calls).toEqual([
    ["chat.cancel", undefined],
    ["(turn ended?)", "s1"],
  ]);
  expect(r.reads()).toBe(1);
});

test("a wait for the turn ends when the turn does, or after its timeout", async () => {
  const waiter = createStopWaiter();
  expect(await waiter.wait(() => false)).toBe(true);
  let running = true;
  const waiting = waiter.wait(() => running, 60_000);
  // A change that leaves the turn running (a forced stop clears only the indicator) ends nothing.
  waiter.changed();
  running = false;
  waiter.changed();
  expect(await waiting).toBe(true);
  expect(await waiter.wait(() => true, 5)).toBe(false);
  // A wait that ended is not resolved again by a later change.
  waiter.changed();
});

test("a paused machine offers Resume; one starting or not the account's offers nothing", async () => {
  const r = rows(machines[1], true);
  expect(r.items.map(label)).toEqual([t("chatMenu.resumeMachine")]);
  await r.pick();
  // Resume never stops a turn.
  expect(r.calls).toEqual([["cloudMachine.resume", { id: "vm_paused" }]]);
  expect(rows(machines[2], false).items).toEqual([]);
  expect(rows({ id: "vm_f", name: "f", stage: "failed" }, false).items).toEqual([]);
  expect(rows(undefined, false).items).toEqual([]);
});

test("a pick the app refuses still reads the list again", async () => {
  const r = rows({ id: "vm_refused", name: "x", stage: "ready" }, false);
  await r.pick();
  expect(r.reads()).toBe(1);
});

test("after a pick the list is read until the machine's stage moves, then no more", async () => {
  setCloudMachinesForTest([]);
  const stages = ["ready", "ready", "paused", "paused"];
  const waits: number[] = [];
  let reads = 0;
  const call = async () => ({
    signedIn: true,
    loaded: true,
    machines: [{ id: "vm_run", name: "Dev-VM-2", stage: stages[reads++] }],
  });
  await readUntilMoved(machines[0]!, call, async (ms) => void waits.push(ms));
  expect(reads).toBe(3);
  expect(waits).toEqual(ACTION_READS_MS.slice(1, 3));
});

test("the reads after a pick stop after the last wait when the stage never moves", async () => {
  setCloudMachinesForTest([]);
  let reads = 0;
  const call = async () => {
    reads += 1;
    return { signedIn: true, loaded: true, machines: [{ id: "vm_run", name: "Dev-VM-2", stage: "ready" }] };
  };
  await readUntilMoved(machines[0]!, call, async () => undefined);
  expect(reads).toBe(ACTION_READS_MS.length);
});
