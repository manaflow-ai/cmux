// What the machine card over a Cloud chat's location chip says (MachineCard.tsx): the machine's
// name, its size, its state, and its last usage reading. Only what the page already has: the
// account's machine record (`cloudMachine.list`, cloudMachines.ts: stage and size) and the cached
// one-minute host reading acpmux keeps on each peer (`_acpmux/status` peers' health,
// machineResources.ts: load, cores, free memory). Nothing here reads, polls or guesses: a number
// the page does not have is left out, never drawn as zero.
import type { ReactNode } from "react";
import type { CloudMachine, CloudMachineSize } from "./cloudMachines";
import type { MachineResources } from "./machineResources";

/// The machine's state as the card's dot and word say it.
export type MachineCardStatus = "awake" | "paused" | "starting" | "failed";

/// `CloudMachineStage` names of a machine on its way up (peerCloudMachine.ts STARTING, and the
/// page's own `resuming` while a Resume it asked for runs).
const STARTING = new Set(["requesting", "creating", "booting", "connecting", "resuming"]);

/// One usage row's reading. `fraction` (0...1) is the bar's fill; absent when the total is unknown,
/// so the row says its number with no bar.
export type MachineCardReading = { fraction?: number };
export type MachineCardLoad = MachineCardReading & { load: number; cores: number };
export type MachineCardMemory = MachineCardReading & { freeGB: number; totalGB?: number };

export type MachineCardModel = {
  /// The machine's name: the chat's machine as the chip names it.
  name: string;
  /// vCPUs, memory (GB) and disk (GB) from the record; absent when it names none.
  specs?: { cpu?: number; memoryGB?: number; diskGB?: number };
  /// Absent when neither the account's record nor acpmux's link says (the card then shows no dot).
  status?: MachineCardStatus;
  /// What the usage section shows: the readings while the machine is awake and read, `unread` while
  /// it is awake with no reading yet, `asleep` while it is not awake (a reading from before it
  /// paused would be stale, so none is shown).
  usage:
    | { kind: "readings"; load?: MachineCardLoad; memory?: MachineCardMemory }
    | { kind: "unread" }
    | { kind: "asleep" };
};

/// The state of `machine` (the account's record), else of acpmux's link to it (`connected`).
export function machineCardStatus(
  machine: Pick<CloudMachine, "stage"> | undefined,
  connected: boolean | undefined,
): MachineCardStatus | undefined {
  if (machine) {
    if (machine.stage === "ready") return "awake";
    if (machine.stage === "paused") return "paused";
    if (machine.stage === "failed") return "failed";
    if (STARTING.has(machine.stage)) return "starting";
  }
  // A machine acpmux is linked to is up, whatever an older list says of it.
  return connected ? "awake" : undefined;
}

/// The chip's dot for `status` (ComposerContext LocationFace `live` / `sleep`): filled while awake,
/// a ring while paused or failed, the spinner while starting; none when the state is unknown.
export function machineCardDot(
  status: MachineCardStatus | undefined,
): { live: boolean; sleep?: "paused" | "resuming" } | undefined {
  switch (status) {
    case "awake":
      return { live: true };
    case "paused":
      return { live: false, sleep: "paused" };
    case "starting":
      return { live: false, sleep: "resuming" };
    case "failed":
      return { live: false };
    default:
      return undefined;
  }
}

/// Bytes in a GB as the size names it (binary: a 16384 MB machine is "16 GB", as the Cloud
/// setup's sizes say it).
const GIB = 1024 ** 3;
const round1 = (value: number) => Math.round(value * 10) / 10;
const clamp = (value: number) => Math.min(1, Math.max(0, value));

/// The record's size in the card's units, or nothing when it names none.
export function machineCardSpecs(size: CloudMachineSize | undefined): MachineCardModel["specs"] {
  if (!size) return undefined;
  const specs: NonNullable<MachineCardModel["specs"]> = {};
  if (size.cpu) specs.cpu = size.cpu;
  if (size.memoryMb) specs.memoryGB = round1(size.memoryMb / 1024);
  if (size.diskMb) specs.diskGB = round1(size.diskMb / 1024);
  return Object.keys(specs).length > 0 ? specs : undefined;
}

/// The card for the chat's machine `name`: its account record (`machine`, matched by name as
/// peerCloudMachine does), acpmux's link to it (`connected`) and its last reading (`resources`).
export function machineCard({
  name,
  machine,
  connected,
  resources,
}: {
  name: string;
  machine?: CloudMachine;
  connected?: boolean;
  resources?: MachineResources;
}): MachineCardModel {
  const status = machineCardStatus(machine, connected);
  const specs = machineCardSpecs(machine?.size);
  const base = { name, ...(specs ? { specs } : {}), ...(status ? { status } : {}) };
  if (status !== "awake") return { ...base, usage: { kind: "asleep" } };
  if (!resources) return { ...base, usage: { kind: "unread" } };
  // The one-minute load against the cores (acpmux's own reading of the machine). A load past the
  // cores fills the bar; the number says how far past.
  const load = resources.load1 ?? resources.coresBusy;
  const loadRow: MachineCardLoad | undefined =
    resources.cores > 0 ? { load, cores: resources.cores, fraction: clamp(load / resources.cores) } : undefined;
  // Free memory is measured (decimal GB in the reading); the total is the machine's size, so the
  // bar is the share in use of what the machine was given. Without a size, the free number alone.
  const freeGB = round1((resources.ramFreeGB * 1e9) / GIB);
  const totalGB = machine?.size?.memoryMb ? machine.size.memoryMb / 1024 : undefined;
  const memory: MachineCardMemory =
    totalGB !== undefined
      ? { freeGB: Math.min(freeGB, round1(totalGB)), totalGB: round1(totalGB), fraction: clamp(1 - freeGB / totalGB) }
      : { freeGB };
  return { ...base, usage: { kind: "readings", ...(loadRow ? { load: loadRow } : {}), memory } };
}

/// What a machine card puts in the environment picker's popover (EnvironmentPicker `card`): the card
/// over the list, its rows (Wake machine) first in the list, and the heading over Continue on.
export type PickerCard = {
  header: ReactNode;
  actions: readonly { id: string; text: string; icon: ReactNode; run(): void }[];
  continueOn: string;
};
