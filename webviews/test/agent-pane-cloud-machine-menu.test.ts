// l10n-allow-file: test fixture machine names, not shipped UI.
//
// Pause and Resume for a chat's Cloud machine in the chat menu (cloudMachineMenu.ts,
// cmuxterm-hq#4755): the chat's peer names one of the account's machines (any case); a running
// machine offers Pause, stopping a running turn first and saying so; a paused one offers Resume;
// one starting, failed or not the account's offers nothing. A pick runs one native call (the app
// checks the click) and reads the account's list again, whatever the app answered. Stop and
// Pause pauses only once the turn has ended; the list is read until the machine's stage moves.
import { expect, test } from "bun:test";
import {
  chatCloudMachine,
  cloudMachineRows,
  createStopWaiter,
} from "../src/agent-session/acpmux/cloudMachineMenu";
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
});

function rows(machine: CloudMachine | undefined, working: boolean, stops = true) {
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
    async () => {
      calls.push(["(turn ended?)", stops]);
      return stops;
    },
  );
  const pick = async (index = 0) => {
    const item = items[index] as Exclude<ChatMenuItem, "separator">;
    item.onSelect!();
    await new Promise((resolve) => setTimeout(resolve, 0));
  };
  return { items, calls, pick, reads: () => reads };
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
    ["(turn ended?)", true],
    ["cloudMachine.pause", { id: "vm_run" }],
  ]);
});

test("a turn that has not stopped is not frozen: no pause, and the list is read again", async () => {
  const r = rows(machines[0], true, false);
  await r.pick();
  expect(r.calls).toEqual([
    ["chat.cancel", undefined],
    ["(turn ended?)", false],
  ]);
  expect(r.reads()).toBe(1);
});

test("a wait for the turn ends when the turn does, or after its timeout", async () => {
  const waiter = createStopWaiter();
  expect(await waiter.wait(() => false)).toBe(true);
  const waiting = waiter.wait(() => true, 60_000);
  waiter.ended();
  expect(await waiting).toBe(true);
  expect(await waiter.wait(() => true, 5)).toBe(false);
  // A wait that ended is not resolved again by a later end.
  waiter.ended();
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
