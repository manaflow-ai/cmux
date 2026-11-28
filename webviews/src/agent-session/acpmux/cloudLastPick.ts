// The agent and model last picked for a Cloud machine: Cloud's own bucket, apart from This Mac's
// (lastPick.ts). Austin, 2026-11-27: "Cloud + autocloud have their own bucket of models and this mac
// is just your local setup ... We should store a state for the local models and a different state for
// the cloud+autocloud so that we can remain consistent". A Cloud pick (cloudAgentPick.ts holds it for
// the page) is remembered here, never in This Mac's last pick; the next page with Cloud picked shows
// it and its first send names it, so a Cloud chat never starts on the agent This Mac last used.
// This page's storage ends with the launch, so the app keeps a copy (`newTab.remember` with
// `place: "cloud"`, AgentPaneLastPicks `cloud`) and the New Tab context brings it back (`lastPicks.cloud`).
import { useMemo, useSyncExternalStore } from "react";
import { postNative } from "./native";

/// `effort`: the level picked with it (model-picker-local-cloud-state), so a level comes back with its
/// model; a pick of another agent names its own or none.
export type CloudLastPick = { harness: string; model?: string; effort?: string };

const STORAGE_KEY = "cmux.acpmux.cloudLastPick";

const listeners = new Set<() => void>();

function parse(value: unknown): CloudLastPick | undefined {
  const pick = value as Partial<CloudLastPick> | null;
  if (typeof pick?.harness !== "string" || pick.harness === "" || pick.harness.length > 128) return undefined;
  const model =
    typeof pick.model === "string" && pick.model !== "" && pick.model.length <= 256 ? pick.model : undefined;
  const effort =
    typeof pick.effort === "string" && pick.effort !== "" && pick.effort !== "default" && pick.effort.length <= 128
      ? pick.effort
      : undefined;
  return { harness: pick.harness, ...(model ? { model } : {}), ...(effort ? { effort } : {}) };
}

type Stored = { pick?: CloudLastPick; picked?: boolean };

function read(): Stored {
  try {
    const parsed = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}") as Stored | null;
    const pick = parse(parsed?.pick);
    return { ...(pick ? { pick } : {}), ...(parsed?.picked === true ? { picked: true } : {}) };
  } catch {
    return {};
  }
}

function write(stored: Stored): void {
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(stored));
  } catch {
    // Storage unavailable: the next Cloud page starts on This Mac's last pick, as before.
  }
  for (const listener of listeners) listener();
}

/** The Cloud pick last made, if any. */
export function cloudLastPick(): CloudLastPick | undefined {
  return read().pick;
}

/** The app's copy (the New Tab context's `lastPicks.cloud`) seeds this page until the page picks. */
export function seedCloudLastPick(value: unknown): void {
  if (read().picked) return;
  const pick = parse(value);
  if (pick) write({ pick });
}

/// Remembers `pick` as Cloud's: the agent and model the next page with Cloud picked starts on.
/// `post` sends it to the app (a page's `callNative`); else the page's native bridge.
export function rememberCloudPick(
  pick: CloudLastPick,
  post?: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): void {
  const kept = parse(pick);
  if (!kept) return;
  const before = read().pick;
  // A pick naming no model keeps the model last picked on the same agent.
  // A pick naming no model keeps the model (and a pick naming no level, the level) last picked on the
  // same agent.
  const same = before?.harness === kept.harness ? before : undefined;
  const model = kept.model ?? same?.model;
  const effort = kept.effort ?? same?.effort;
  const next: CloudLastPick = { harness: kept.harness, ...(model ? { model } : {}), ...(effort ? { effort } : {}) };
  write({ pick: next, picked: true });
  const params = {
    agent: next.harness,
    ...(next.model ? { model: next.model } : {}),
    ...(next.effort ? { effort: next.effort } : {}),
    place: "cloud",
  };
  const direct = post ? undefined : globalThis.window?.cmuxAcpmuxActions?.["newTab.remember"];
  const send = post ?? ((method: string, body: typeof params) => (direct ? direct(body) : postNative(method, body)));
  try {
    void Promise.resolve(send("newTab.remember", params)).catch(() => undefined);
  } catch {
    // No bridge (a test page): this page still keeps it.
  }
}

/** Tests only: forgets the pick. */
export function clearCloudLastPick(): void {
  try {
    globalThis.localStorage?.removeItem(STORAGE_KEY);
  } catch {
    // Nothing kept.
  }
  for (const listener of listeners) listener();
}

/** `cloudLastPick()`, drawn again when a pick is remembered or the app's copy arrives. */
export function useCloudLastPick(): CloudLastPick | undefined {
  const key = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => JSON.stringify(cloudLastPick() ?? null),
    () => "null",
  );
  return useMemo(() => (JSON.parse(key) as CloudLastPick | null) ?? undefined, [key]);
}
