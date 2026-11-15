// The signed-in account's Cloud machines, as the app holds them (`cloudMachine.list`,
// CmuxNextAgentPane AgentPaneCloudMachineRequest), for the composer's machine list. acpmux lists
// only the machines it has a link to (`_acpmux/status` peers), so a paused Cloud machine, or one
// this Mac's acpmux never linked, was missing; the list shows those too, with their stage, and a
// pick resumes a paused one (`cloudMachine.resume`) or opens the machine (`cloudMachine.open`).
// Leo, 2026-10-26: "the dropdown should show the states of stuff when you've done the acp things
// or any kind of connectivity."
import { useSyncExternalStore } from "react";
import { environmentReady, type Environment } from "./environments";
import { postNative } from "./native";
import { activeTeamFromReply, type ActiveTeamTag } from "./TeamTag";

/// One machine of the account: its id, name and `CloudMachineStage` name (`ready`, `paused`,
/// `requesting`, `creating`, `booting`, `connecting`, `failed`). `evictAt` (epoch ms) is when a
/// machine left paused for 30 days is deleted unless it resumes; absent when the server does not say.
export type CloudMachine = { id: string; name: string; stage: string; evictAt?: number };
/// A Cloud machine as a row of the machine list: a Cloud environment carrying its machine.
export type CloudMachineRow = Environment & { cloudMachine: CloudMachine };

/// Whether the app's Cloud account is signed in. `undefined` means the app did not provide an
/// explicit account state (for example, a fresh home where Cloud is not available yet). The
/// picker's Cloud row reads Sign in for Cloud only on an explicit `false` (EnvironmentPicker).
///
/// Whether the last answer said signed in is kept in this origin's localStorage (every agent page
/// shares one website data store, newtab/settledCache.ts) and read when the page loads, so a menu
/// opened before this page's own `cloudMachine.list` reply draws its settled Cloud row on its first
/// frame. Leo, 2026-11-07, of "Sign in for Cloud" showing and then vanishing as the machine menu
/// opened: "ideally this never happens ... The thing becomes just one state instead of rapidly
/// switching to another." Only the yes or no is kept, never the account's machines (names or ids):
/// a page after an account switch must never show or act on the previous account's machines, which
/// come from this page's own reply alone. A reply replaces it; a refused read clears it.
const ACCOUNT_KEY = "cmux.acpmux.cloud.signedIn";

function accountStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

function readKeptSignedIn(): boolean | undefined {
  try {
    const raw = accountStorage()?.getItem(ACCOUNT_KEY);
    return raw === "true" ? true : raw === "false" ? false : undefined;
  } catch {
    return undefined;
  }
}

function keepSignedIn(signedIn: boolean | undefined): void {
  try {
    const store = accountStorage();
    if (signedIn === undefined) store?.removeItem(ACCOUNT_KEY);
    else store?.setItem(ACCOUNT_KEY, String(signedIn));
  } catch {
    // A blocked or full store only leaves the next page to wait for its own reply.
  }
}

let accountSignedIn: boolean | undefined;

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
    const { id, name, stage, evictAt } = (raw ?? {}) as Record<string, unknown>;
    if (typeof id !== "string" || !id || typeof name !== "string" || !name || typeof stage !== "string") continue;
    machines.push(
      typeof evictAt === "number" && Number.isFinite(evictAt) && evictAt > 0
        ? { id, name, stage, evictAt }
        : { id, name, stage },
    );
  }
  return machines;
}

export function cloudSignedInFromReply(reply: unknown): boolean | undefined {
  const value = reply as { signedIn?: unknown } | null | undefined;
  return typeof value?.signedIn === "boolean" ? value.signedIn : undefined;
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

/// `CloudMachineStage` names of a machine on its way up (Swift CloudMachineStage: `resuming` while
/// the server takes a resume, then `booting` and `connecting`; a page's own Resume reads `requesting`).
const STARTING_STAGES = new Set(["requesting", "resuming", "creating", "booting", "connecting"]);

/// The account's one machine named `name` (any case, as the app matches a peer to a Cloud machine by
/// its title). Two of that name give none: a Resume must never start the other one.
export function uniqueCloudMachine(machines: readonly CloudMachine[], name: string): CloudMachine | undefined {
  const named = machines.filter((machine) => lower(machine.name) === lower(name));
  return named.length === 1 ? named[0] : undefined;
}

/// What a Cloud machine acpmux lists but has no link to is, when the account says it sleeps: its
/// link state reads `paused` or `resuming` in place of acpmux's `reconnecting` or `offline`, so the
/// composer and the picker show a calm pause, never a broken link. With `pickable` (a new chat's
/// list), a paused one also carries its machine, so a pick resumes it and the chat moves there once
/// acpmux links it (ComposerContext `pickCloudMachine`); a resuming one stays greyed until then.
/// Cloud machines are about to pause on their own when idle, and between tool calls (cmux-platform
/// docs/agent-turn-sleep.md), so a pause has to read as an ordinary state.
/// Whether the account's machine named `name` is paused or on its way up (a resume): a Cloud
/// machine that sleeps, never one that is gone. Reads the page's copy of the app's list as it is.
export function cloudMachineAsleep(name: string | undefined, list: readonly CloudMachine[] = machines): boolean {
  if (!name) return false;
  const machine = uniqueCloudMachine(list, name);
  return machine !== undefined && (machine.stage === "paused" || STARTING_STAGES.has(machine.stage));
}

export function withCloudSleep<T extends Environment>(
  listed: readonly T[],
  machines: readonly CloudMachine[],
  pickable: boolean,
): (T | (T & CloudMachineRow))[] {
  if (machines.length === 0) return [...listed];
  return listed.map((environment) => {
    if (environment.kind !== "cloud" || environmentReady(environment) || isCloudMachineRow(environment))
      return environment;
    const machine = uniqueCloudMachine(machines, environment.label);
    if (machine?.stage === "paused")
      return { ...environment, state: "paused", ...(pickable ? { cloudMachine: machine } : {}) };
    if (machine && STARTING_STAGES.has(machine.stage)) return { ...environment, state: "resuming" };
    return environment;
  });
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
// The page starts from the last signed-in answer kept, never from nothing; its machines are its own.
accountSignedIn = readKeptSignedIn();
const listeners = new Set<() => void>();
let inFlight: Promise<void> | undefined;
/// Bumped by a reset: a reply to a read asked before it is dropped.
let generation = 0;

function publish(next: readonly CloudMachine[]): void {
  if (JSON.stringify(next) === JSON.stringify(machines)) return;
  machines = next;
  for (const listener of listeners) listener();
}

/// The team the account works in (the reply's `team`), shown on the Cloud row and face. Kept only
/// in memory, from this page's own reply: an account switch never shows the previous team.
let activeTeam: ActiveTeamTag | undefined;

function publishTeam(next: ActiveTeamTag | undefined): void {
  if (next?.name === activeTeam?.name && next?.personal === activeTeam?.personal) return;
  activeTeam = next;
  for (const listener of listeners) listener();
}

function publishAccount(next: boolean | undefined): void {
  if (next === accountSignedIn) return;
  accountSignedIn = next;
  for (const listener of listeners) listener();
}

/// Reads the app's list again. A read the app refused clears both snapshots: the previous
/// account's machines and signed-in state cannot be trusted after it. With no app to ask (outside
/// the app, or while its bridge reconnects: `native.not_connected`) the list is left as it was.
export function refreshCloudMachines(call: Call = postNative): Promise<void> {
  const asked = generation;
  inFlight ??= call("cloudMachine.list", {})
    .then((reply) => {
      if (asked === generation) {
        const signedIn = cloudSignedInFromReply(reply);
        const list = cloudMachinesFromReply(reply);
        keepSignedIn(signedIn);
        publishAccount(signedIn);
        const answer = reply as { team?: unknown; teams?: unknown } | null | undefined;
        publishTeam(signedIn ? activeTeamFromReply(answer?.team, answer?.teams) : undefined);
        publish(list);
      }
    })
    .catch((error: unknown) => {
      if ((error as { code?: unknown } | null)?.code === "native.not_connected") return;
      if (asked === generation) {
        keepSignedIn(undefined);
        publishAccount(undefined);
        publishTeam(undefined);
        publish([]);
      }
    })
    .finally(() => {
      if (asked === generation) inFlight = undefined;
    });
  return inFlight;
}

/// The app's word that the account's active team changed (`AgentPaneCloudMachines.teamChangeScript`).
export const CLOUD_TEAM_CHANGE_EVENT = "cmux-cloud-team-change";

/// Reads the list again on each team change, so the Cloud row and face name the new team at once.
/// A read already in flight may carry the old team: it is dropped for a fresh one.
export function followCloudTeamChange(call: Call = postNative, target: EventTarget = window): () => void {
  const changed = () => {
    generation += 1;
    inFlight = undefined;
    void refreshCloudMachines(call);
  };
  target.addEventListener(CLOUD_TEAM_CHANGE_EVENT, changed);
  return () => target.removeEventListener(CLOUD_TEAM_CHANGE_EVENT, changed);
}

if (typeof window !== "undefined") followCloudTeamChange();

/// Resumes or opens the machine (one click: the app checks the gesture and the machine), then
/// reads the list again so its new stage shows; a resume shows as starting at once.
export function runCloudMachine(machine: CloudMachine, call: Call = postNative): Promise<void> {
  const method = cloudMachineAction(machine) === "resume" ? "cloudMachine.resume" : "cloudMachine.open";
  // A resume shows at once: the paused row reads Starting… while the app wakes the machine, not
  // Paused · Resume until the next read (a second pick would ask again).
  if (method === "cloudMachine.resume")
    publish(machines.map((other) => (other.id === machine.id ? { ...other, stage: "requesting" } : other)));
  // A list read already in flight was asked before the action: wait it out, then read again. A
  // refused action shows as Couldn't start (the list would only say Paused again), so a pick that
  // waits on the machine stops waiting instead of reading Starting… for ever.
  let refused = false;
  return call(method, { id: machine.id })
    .catch(() => {
      refused = true;
    })
    .then(() => inFlight)
    .then(() =>
      refused
        ? publish(machines.map((other) => (other.id === machine.id ? { ...other, stage: "failed" } : other)))
        : refreshCloudMachines(call),
    );
}

/// After a pause or resume the app runs the action in the background and its list catches up
/// when the action's own list read lands (a resume may take as long as a machine's start, up to
/// 16 minutes): the list is read at these waits (ms) after the pick, from every second to every
/// minute, and the reads stop once the machine's stage moved on, or after the last one (16
/// minutes in all).
export const ACTION_READS_MS = [0, 1_000, 2_000, 4_000, 8_000, 15_000, 30_000, ...Array<number>(15).fill(60_000)];

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/// Reads the list until `machine` (as it was when picked) shows another stage, or is gone.
export async function readUntilMoved(
  machine: CloudMachine,
  call: Call = postNative,
  wait: (ms: number) => Promise<void> = pause,
): Promise<void> {
  // A read already in flight was asked before the action.
  await inFlight;
  for (const ms of ACTION_READS_MS) {
    if (ms > 0) await wait(ms);
    await refreshCloudMachines(call);
    const now = machines.find((candidate) => candidate.id === machine.id);
    if (now?.stage !== machine.stage) return;
  }
}

export function useCloudMachines(): readonly CloudMachine[] {
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

export function useCloudSignedIn(): boolean | undefined {
  return useSyncExternalStore(subscribe, accountSnapshot, accountSnapshot);
}

/// The account state shown in capture diagnostics. This is deliberately read-only and mirrors the
/// value consumed by EnvironmentPicker, including the fresh-home `undefined` state.
export function cloudSignedInForDebug(): boolean | undefined {
  return accountSignedIn;
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
  keepSignedIn(undefined);
  publishAccount(undefined);
  publish(next);
}

/// Tests may seed the account state independently of the machine rows.
export function setCloudMachinesForTestAccount(next: boolean | undefined): void {
  publishAccount(next);
}

const accountSnapshot = () => accountSignedIn;
const teamSnapshot = () => activeTeam;
/// The team as last read (tests and capture diagnostics).
export const currentCloudTeam = teamSnapshot;

/// The team the signed-in account works in, once the app said; undefined before or signed out.
export function useCloudTeam(): ActiveTeamTag | undefined {
  return useSyncExternalStore(subscribe, teamSnapshot, teamSnapshot);
}

/// Tests: the team as if the app's reply named it.
export function setCloudTeamForTest(next: ActiveTeamTag | undefined): void {
  publishTeam(next);
}

/// Tests: the page loading again, starting from what localStorage kept (as at module load).
export function reloadKeptCloudAccountForTest(): void {
  generation += 1;
  inFlight = undefined;
  publishAccount(readKeptSignedIn());
  publish([]);
}
