// The signed-in account's Cloud machines, as the app holds them (`cloudMachine.list`,
// CmuxNextAgentPane AgentPaneCloudMachineRequest), for the composer's machine list. acpmux lists
// only the machines it has a link to (`_acpmux/status` peers), so a paused Cloud machine, or one
// this Mac's acpmux never linked, was missing; the list shows those too, with their stage, and a
// pick resumes a paused one (`cloudMachine.resume`) or opens the machine (`cloudMachine.open`).
// Leo, 2026-10-26: "the dropdown should show the states of stuff when you've done the acp things
// or any kind of connectivity."
import { useSyncExternalStore } from "react";
import type { Environment } from "./environments";
import { postNative } from "./native";

/// One machine of the account: its id, name and `CloudMachineStage` name (`ready`, `paused`,
/// `requesting`, `creating`, `booting`, `connecting`, `failed`).
export type CloudMachine = { id: string; name: string; stage: string };
/// A Cloud machine as a row of the machine list: a Cloud environment carrying its machine.
export type CloudMachineRow = Environment & { cloudMachine: CloudMachine };

type Call = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// A row id no acpmux peer name takes (`cloud-machine:` and the machine's id).
const ROW_PREFIX = "cloud-machine:";
const MAX_ROWS = 200;

/// The rows of a `cloudMachine.list` reply; none unless the app holds the signed-in account's list.
export function cloudMachinesFromReply(reply: unknown): CloudMachine[] {
  const value = reply as { signedIn?: unknown; loaded?: unknown; machines?: unknown } | null | undefined;
  if (value?.signedIn !== true || value.loaded !== true || !Array.isArray(value.machines)) return [];
  const machines: CloudMachine[] = [];
  for (const raw of value.machines.slice(0, MAX_ROWS)) {
    const { id, name, stage } = (raw ?? {}) as Record<string, unknown>;
    if (typeof id !== "string" || !id || typeof name !== "string" || !name || typeof stage !== "string") continue;
    machines.push({ id, name, stage });
  }
  return machines;
}

/// The account's machines the list does not already have: one acpmux lists by the same name (any
/// case) keeps acpmux's row and its live state, as the app matches a peer to a Cloud machine by its
/// title (MachineRegistry machineName(peer:)). Each row is a Cloud row, in Cloud and VMs.
export function cloudMachineRows(
  machines: readonly CloudMachine[],
  listed: readonly Pick<Environment, "id" | "label">[],
): CloudMachineRow[] {
  const names = new Set(listed.flatMap((environment) => [environment.id, environment.label].map(lower)));
  // Not connected: acpmux has no link to it, so it is no chat pick and takes no ⌥⌘ digit
  // (environments.ts environmentReady); a pick runs its machine action instead.
  return machines
    .filter((machine) => !names.has(lower(machine.name)))
    .map((machine) => ({
      id: ROW_PREFIX + machine.id,
      label: machine.name,
      kind: "cloud",
      connected: false,
      cloudMachine: machine,
    }));
}

const lower = (text: string) => text.toLowerCase();

/// The machine list with the account's Cloud machines merged in. A machine acpmux lists as a peer
/// keeps acpmux's row. A row that is only the host an earlier Cloud chat ran on (not a peer) gives
/// way to the account's machine of that name, which knows its stage and runs Resume or Open, except
/// the row of the machine the chat is on now (`keep`).
export function withCloudMachines<T extends Pick<Environment, "id" | "label" | "kind">>(
  listed: readonly T[],
  machines: readonly CloudMachine[],
  peers: readonly string[],
  keep: string,
): (T | CloudMachineRow)[] {
  const peerSet = new Set(peers);
  const rows = cloudMachineRows(
    machines,
    listed.filter(
      (environment) => environment.kind === "local" || peerSet.has(environment.id) || environment.id === keep,
    ),
  );
  const taken = new Set(rows.map((row) => lower(row.label)));
  const kept = listed.filter(
    (environment) =>
      environment.kind === "local" ||
      peerSet.has(environment.id) ||
      environment.id === keep ||
      !taken.has(lower(environment.label)),
  );
  return [...kept, ...rows];
}

export function isCloudMachineRow(environment: Environment): environment is CloudMachineRow {
  return (environment as Partial<CloudMachineRow>).cloudMachine !== undefined;
}

/// What a pick does to the machine: a paused one resumes; any other opens (its first workspace,
/// connecting it and showing its progress while it starts).
export function cloudMachineAction(machine: CloudMachine): "resume" | "open" {
  return machine.stage === "paused" ? "resume" : "open";
}

// The page's copy of the app's list: every composer reads it, and an open machine list reads it
// again (useMachineRefresh), one request at a time.
let machines: readonly CloudMachine[] = [];
const listeners = new Set<() => void>();
let inFlight: Promise<void> | undefined;
/// Bumped by a reset: a reply to a read asked before it is dropped.
let generation = 0;

function publish(next: readonly CloudMachine[]): void {
  if (JSON.stringify(next) === JSON.stringify(machines)) return;
  machines = next;
  for (const listener of listeners) listener();
}

/// Reads the app's list again. Outside the app, or when the app refuses, the list is left as it was.
export function refreshCloudMachines(call: Call = postNative): Promise<void> {
  const asked = generation;
  inFlight ??= call("cloudMachine.list", {})
    .then((reply) => {
      if (asked === generation) publish(cloudMachinesFromReply(reply));
    })
    .catch(() => undefined)
    .finally(() => {
      if (asked === generation) inFlight = undefined;
    });
  return inFlight;
}

/// Resumes or opens the machine (one click: the app checks the gesture and the machine), then
/// reads the list again so its new stage shows.
export function runCloudMachine(machine: CloudMachine, call: Call = postNative): Promise<void> {
  const method = cloudMachineAction(machine) === "resume" ? "cloudMachine.resume" : "cloudMachine.open";
  // A list read already in flight was asked before the action: wait it out, then read again.
  return call(method, { id: machine.id })
    .catch(() => undefined)
    .then(() => inFlight)
    .then(() => refreshCloudMachines(call));
}

export function useCloudMachines(): readonly CloudMachine[] {
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
const snapshot = () => machines;

/// Tests: the list as if the app answered `next`; a read still in flight changes nothing after.
export function setCloudMachinesForTest(next: readonly CloudMachine[]): void {
  generation += 1;
  inFlight = undefined;
  publish(next);
}
