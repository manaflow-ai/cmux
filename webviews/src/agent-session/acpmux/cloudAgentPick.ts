// The agent, model and level picked for a new chat whose first send starts it on a Cloud machine
// (cmux#51731). With Cloud (or Auto, which may start it there) picked the pick is the machine's, not
// this Mac's: it starts no chat here (a `chat.new` on this Mac would fail for an agent only the machine
// carries) and never becomes this Mac's remembered pick (lastPick.ts, acpmux's saved defaults).
//
// Cloud keeps its own pick, apart from This Mac's (model-picker-local-cloud-state): This Mac's side is
// this Mac's acpmux (its saved defaults, which every pick in a local chat writes) and lastPick.ts; the
// Cloud side is the pick here, which the app keeps across launches (`newTab.remember` `side: "cloud"`,
// the New Tab context's `lastPicks.cloud`, `newTab.cloudPick`'s `cloudAgent`). Switching Runs On
// between This Mac and Cloud shows each side's own pick again; neither ever writes the other's.
//
// One source of truth for the chips and the send: the chips draw `cloudPickShown` and publish what they
// drew (`publishCloudAgentShown`); both Cloud sends (the chat composer, the New Tab page) send
// `cloudStartPick`, that same pick. Before, each of the three worked the agent out on its own (a held
// pick, else the page's local agent, else the last local pick), so the chip and the start could name
// different agents, models or levels.
//
// A started Cloud chat's pick of another agent hands it to the new Cloud chat it opens (commandPlace.ts),
// which holds it here. One page holds one pick, as cloudModePick.ts holds the mode.
import { useSyncExternalStore } from "react";
import { CLOUD_DEFAULT_AGENT, cloudStartAgent } from "./harnessModes";
import { isDefaultChoice } from "./defaultChoice";
import { postNative } from "./native";

/// `effort`: the level picked for it (cmux#59716), which the Cloud send carries; it stays with the
/// agent across a model pick, and a pick of another agent drops it.
export type CloudAgentPick = { harness: string; model?: string; effort?: string; handed?: true };

let held: CloudAgentPick | undefined;
/// What the chips last drew for the Cloud start (`publishCloudAgentShown`).
let shown: CloudAgentPick | undefined;
/// The app's copy of Cloud's remembered pick, as the New Tab context or `newTab.cloudPick` named it.
let appCopy: CloudAgentPick | undefined;
/// This page remembered a pick itself: an older app copy (a context made before it) no longer seeds.
let pickedHere = false;
const listeners = new Set<() => void>();

const STORAGE_KEY = "cmux.acpmux.cloudAgentPick.v1";

function emit() {
  for (const listener of listeners) listener();
}

/// A pick the app can keep (AgentPaneRequest+Decoding `newTab.remember`): a harness of at most 128
/// characters, a model of at most 256 and a level of at most 128.
function valid(value: unknown): CloudAgentPick | undefined {
  const pick = value as Partial<CloudAgentPick> | null | undefined;
  if (typeof pick?.harness !== "string" || !pick.harness || pick.harness.length > 128) return undefined;
  const model = typeof pick.model === "string" && pick.model && pick.model.length <= 256 ? pick.model : undefined;
  const effort =
    typeof pick.effort === "string" && pick.effort && pick.effort.length <= 128 && pick.effort !== "default"
      ? pick.effort
      : undefined;
  return { harness: pick.harness, ...(model ? { model } : {}), ...(effort ? { effort } : {}) };
}

function readStored(): CloudAgentPick | undefined {
  try {
    return valid(JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null"));
  } catch {
    return undefined;
  }
}

/// Cloud's remembered pick: this run's copy, else the app's (kept across launches).
export function rememberedCloudAgentPick(): CloudAgentPick | undefined {
  return readStored() ?? appCopy;
}

/// The person picked `pick` for Cloud: kept for this run and sent to the app, which keeps it across
/// launches. Never This Mac's pick.
function remember(pick: CloudAgentPick): void {
  const kept = valid(pick);
  if (!kept) return;
  pickedHere = true;
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(kept));
  } catch {
    // A full or blocked store: the app's copy still names it on the next page.
  }
  const params = {
    side: "cloud",
    agent: kept.harness,
    ...(kept.model ? { model: kept.model } : {}),
    ...(kept.effort ? { effort: kept.effort } : {}),
  };
  // No page host (a test, a page still loading): this run's copy alone keeps it.
  if (typeof window === "undefined") return;
  const direct = window.cmuxAcpmuxActions?.["newTab.remember"];
  try {
    void (direct ? direct(params) : postNative("newTab.remember", params)).catch(() => undefined);
  } catch {
    // No bridge to the app: this run's copy still names it.
  }
}

/// The app's copy (the New Tab context's `lastPicks.cloud`, `newTab.cloudPick`'s `cloudAgent`). A pick
/// this page made since wins; the copy is read when this run has none of its own.
export function seedCloudAgentPick(value: unknown): void {
  const pick = valid(value);
  if (!pick || pickedHere) return;
  appCopy = pick;
  emit();
}

/** Holds `pick` for the next Cloud start, and remembers it as Cloud's pick; a later pick replaces it. A
 * pick of the same agent with no level keeps the level already held (or remembered) for it. */
export function holdCloudAgentPick(pick: CloudAgentPick): void {
  if (!pick.harness) return;
  const before = held ?? rememberedCloudAgentPick();
  const effort = pick.effort ?? (before?.harness === pick.harness ? before.effort : undefined);
  held = {
    harness: pick.harness,
    ...(pick.model ? { model: pick.model } : {}),
    ...(effort ? { effort } : {}),
    ...(pick.handed ? { handed: true as const } : {}),
  };
  remember(held);
  emit();
}

/** Another tab takes this page (a Cmd-T adoption, a session adoption): the pick an earlier tab made is
 * dropped, so it never starts this tab's chat (cmux#59716: a page that held Claude for Cloud started
 * Claude for a tab showing Codex). A pick handed to this tab by its own handshake (New Cloud Chat, a
 * started Cloud chat's pick of another agent) stays through the first adoption, which the host can
 * replay right after that handshake; it is this tab's. Cloud's remembered pick stays: the next tab with
 * Cloud picked shows it, as the chips say. */
export function dropCloudAgentPickForAdoption(): void {
  if (held?.handed) {
    const { handed: _handed, ...rest } = held;
    held = rest;
    emit();
    return;
  }
  clearCloudAgentPick();
}

/** Holds `effort` for the Cloud start of `harness` (the agent the chips show), keeping its held (or
 * remembered) model, else `model`, the one the chips show for it, so a level picked alone never drops the
 * shown model. A level is a Cloud pick like the model: this Mac starts no chat for it (cmux#59716: a level
 * picked on a New Tab with Cloud started this Mac's own agent, and the chips showed that agent). */
export function holdCloudAgentEffort(harness: string | undefined, effort: string, model?: string): void {
  if (!harness || !effort) return;
  const before = held ?? rememberedCloudAgentPick();
  const base =
    before?.harness === harness
      ? { ...before, ...(before.model ? {} : model ? { model } : {}) }
      : { harness, ...(model ? { model } : {}) };
  held = { ...base, effort };
  remember(held);
  emit();
}

/** The held pick, if any. */
export function cloudAgentPick(): CloudAgentPick | undefined {
  return held;
}

/** Drops this page's held pick (a page another tab adopts); Cloud's remembered pick stays. */
export function clearCloudAgentPick(): void {
  held = undefined;
  shown = undefined;
  emit();
}

/** Tests only: a new launch, with nothing held, shown or remembered. */
export function forgetCloudAgentPicksForTests(): void {
  held = undefined;
  shown = undefined;
  appCopy = undefined;
  pickedHere = false;
  try {
    globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // No store.
  }
  emit();
}

/// The Cloud machine's agent for the agent this Mac's side shows (`local`): the same agent when the
/// machine carries it (a Mac-only profile runs its base agent there: cloudStartAgent), with its model;
/// else the machine's default agent and no model of this Mac's.
function fromThisMac(local: { harness?: string; model?: string; family?: string } | undefined): CloudAgentPick {
  const agent = cloudStartAgent(local?.family, local?.harness);
  if (!agent.named || !agent.harness) return { harness: CLOUD_DEFAULT_AGENT };
  const model = local?.model && !isDefaultChoice({ id: local.model }) ? local.model : undefined;
  return { harness: agent.harness, ...(model ? { model } : {}) };
}

/** The pick the chips show for a Cloud start: the one held on this page, else Cloud's remembered pick,
 * else (no Cloud pick was ever made) the agent This Mac's side shows when the machine carries it, else
 * the machine's default agent. `defaultModel` names the model a pick naming none starts on (the model
 * catalog's default for that agent), so the chip and the start name one model. */
export function cloudPickShown(
  local: { harness?: string; model?: string; family?: string } | undefined,
  defaultModel?: (harness: string) => string | undefined,
  picked: CloudAgentPick | undefined = held ?? rememberedCloudAgentPick(),
): CloudAgentPick {
  const base = picked
    ? {
        harness: picked.harness,
        ...(picked.model ? { model: picked.model } : {}),
        ...(picked.effort ? { effort: picked.effort } : {}),
      }
    : fromThisMac(local);
  if (base.model && !isDefaultChoice({ id: base.model })) return base;
  const { model: _none, ...rest } = base;
  const model = defaultModel?.(base.harness);
  return model && !isDefaultChoice({ id: model }) ? { ...rest, model } : rest;
}

/** The chips drew `pick` for the Cloud start: the send sends it (`cloudStartPick`). */
export function publishCloudAgentShown(pick: CloudAgentPick | undefined): void {
  shown = pick;
}

/** The agent, model and level a Cloud start sends: what the chips drew, else what they would draw. */
export function cloudStartPick(
  local: { harness?: string; model?: string; family?: string } | undefined,
): CloudAgentPick {
  return shown ?? cloudPickShown(local);
}

function snapshotKey(): string {
  return JSON.stringify([held ?? null, rememberedCloudAgentPick() ?? null]);
}

/** The held pick, drawn again when it changes. */
export function useCloudAgentPick(): CloudAgentPick | undefined {
  return useSyncExternalStore(
    subscribe,
    () => held,
    () => held,
  );
}

/** The pick the chips start from (held, else remembered), drawn again when either changes. */
export function useCloudAgentPicked(): CloudAgentPick | undefined {
  const key = useSyncExternalStore(subscribe, snapshotKey, snapshotKey);
  return pickedFromKey(key);
}

let lastKey = "";
let lastPicked: CloudAgentPick | undefined;
function pickedFromKey(key: string): CloudAgentPick | undefined {
  if (key === lastKey) return lastPicked;
  lastKey = key;
  const [h, r] = JSON.parse(key) as [CloudAgentPick | null, CloudAgentPick | null];
  lastPicked = h ?? r ?? undefined;
  return lastPicked;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
