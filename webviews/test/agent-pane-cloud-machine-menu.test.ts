// l10n-allow-file: test fixture machine names, not shipped UI.
//
// Pause and Resume for a chat's Cloud machine in the chat menu (cloudMachineMenu.ts,
// cmuxterm-hq#4755): the chat's peer names one of the account's machines (any case); a running
// machine offers Pause, stopping a running turn first and saying so; a paused one offers Resume;
// one starting, failed or not the account's offers nothing. A pick runs one native call (the app
// checks the click) and reads the account's list again, whatever the app answered.
import { expect, test } from "bun:test";
import { chatCloudMachine, cloudMachineRows } from "../src/agent-session/acpmux/cloudMachineMenu";
import type { CloudMachine } from "../src/agent-session/acpmux/cloudMachines";
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

function rows(machine: CloudMachine | undefined, working: boolean) {
  const calls: [string, unknown][] = [];
  let reads = 0;
  const call = async (method: string, params?: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "cloudMachine.pause" && params?.id === "vm_refused") throw new Error("gesture");
    return {};
  };
  const items = cloudMachineRows(machine, working, t, call, () => (reads += 1));
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
    ["cloudMachine.pause", { id: "vm_run" }],
  ]);
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
