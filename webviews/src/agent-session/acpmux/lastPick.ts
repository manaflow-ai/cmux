// The harness and model picked last (Leo 2026-10-11): a New Tab, a new chat and a relaunch start on
// it instead of a harness's first model. Kept for every folder and for the folder it was picked in;
// in that folder its own pick wins. The app keeps it (`newTab.remember`): this page's storage ends
// with the launch (its web view's store is not persistent), so the New Tab context brings the app's
// copy back (`lastPicks`, seedLastPicks). A missing or blocked store only means the harness's own
// default.
import { useMemo, useSyncExternalStore } from "react";
import { isDefaultChoice } from "./defaultChoice";
import { postNative } from "./native";

export type LastPick = { harness: string; model: string };
/// `picked`: this page picked since its storage began. The app's copy a later context carries can
/// be older than that pick (a context built before it, a reloaded page), so it no longer seeds.
type Stored = { global?: LastPick; folders?: Record<string, LastPick>; picked?: boolean };

const STORAGE_KEY = "cmux.acpmux.lastPick";
/// The folders kept; the oldest pick goes first.
const MAX_FOLDERS = 50;

function isPick(value: unknown): value is LastPick {
  const pick = value as Partial<LastPick> | null;
  return (
    typeof pick?.harness === "string" && typeof pick.model === "string" && pick.harness !== "" && pick.model !== ""
  );
}

type FolderPick = LastPick & { folder: string };

function isFolderPick(value: unknown): value is FolderPick {
  return (
    isPick(value) && typeof (value as Partial<FolderPick>).folder === "string" && (value as FolderPick).folder !== ""
  );
}

const listeners = new Set<() => void>();
function changed(): void {
  for (const listener of listeners) listener();
}

function write(stored: Stored): void {
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(stored));
  } catch {
    // Storage unavailable: the next new chat starts on the harness's own default.
  }
}

/// The app's copy (the New Tab context's `lastPicks`: `{global, folders: [{folder, harness, model}]}`,
/// oldest folder first) replaces this page's until the page picks.
export function seedLastPicks(value: unknown): void {
  if (read().picked || !value || typeof value !== "object") return;
  const { global, folders } = value as { global?: unknown; folders?: unknown };
  const kept = (Array.isArray(folders) ? folders.filter(isFolderPick) : []).slice(-MAX_FOLDERS);
  write({
    ...(isPick(global) ? { global: { harness: global.harness, model: global.model } } : {}),
    folders: Object.fromEntries(kept.map((pick) => [pick.folder, { harness: pick.harness, model: pick.model }])),
  });
  changed();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

/// `lastPick(folder)`, drawn again when a pick is remembered or the app's copy arrives.
export function useLastPick(folder?: string): LastPick | undefined {
  const key = useSyncExternalStore(subscribe, () => JSON.stringify(lastPick(folder) ?? null));
  return useMemo(() => (JSON.parse(key) as LastPick | null) ?? undefined, [key]);
}

function read(): Stored {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    if (!parsed || typeof parsed !== "object") return {};
    const { global, folders, picked } = parsed as Stored;
    return {
      ...(isPick(global) ? { global } : {}),
      ...(picked === true ? { picked } : {}),
      folders: Object.fromEntries(Object.entries(folders ?? {}).filter((entry) => isPick(entry[1]))),
    };
  } catch {
    return {};
  }
}

/// Remembers `pick` for every folder and for `folder`. The agent's own "default" is not a pick.
export function rememberPick(pick: LastPick, folder?: string): void {
  // The app keeps what it can take (AgentPaneRequest+Decoding): a longer value is no pick.
  if (!isPick(pick) || isDefaultChoice({ id: pick.model })) return;
  if (pick.harness.length > 128 || pick.model.length > 256 || (folder?.length ?? 0) > 4096) return;
  const stored = read();
  const folders = { ...stored.folders };
  if (folder) {
    delete folders[folder];
    folders[folder] = pick;
  }
  write({ global: pick, folders: Object.fromEntries(Object.entries(folders).slice(-MAX_FOLDERS)), picked: true });
  changed();
  const params = { agent: pick.harness, model: pick.model, ...(folder ? { folder } : {}) };
  const direct = window.cmuxAcpmuxActions?.["newTab.remember"];
  void (direct ? direct(params) : postNative("newTab.remember", params)).catch(() => undefined);
}

/// The last pick in `folder`, else the last pick anywhere.
export function lastPick(folder?: string): LastPick | undefined {
  const stored = read();
  return (folder ? stored.folders?.[folder] : undefined) ?? stored.global;
}

/// The model last picked on `harness`: in `folder` first, then anywhere.
export function lastModel(harness: string, folder?: string): string | undefined {
  const stored = read();
  const inFolder = folder ? stored.folders?.[folder] : undefined;
  if (inFolder?.harness === harness) return inFolder.model;
  return stored.global?.harness === harness ? stored.global.model : undefined;
}
