// The harness and model picked last (Leo 2026-10-11): a New Tab, a new chat and a relaunch start on
// it instead of a harness's first model. Kept for every folder and for the folder it was picked in;
// in that folder its own pick wins. Per viewer, in this page's storage; a missing or blocked store
// only means the harness's own default.
import { isDefaultChoice } from "./defaultChoice";

export type LastPick = { harness: string; model: string };
type Stored = { global?: LastPick; folders?: Record<string, LastPick> };

const STORAGE_KEY = "cmux.acpmux.lastPick";
/// The folders kept; the oldest pick goes first.
const MAX_FOLDERS = 50;

function isPick(value: unknown): value is LastPick {
  const pick = value as Partial<LastPick> | null;
  return (
    typeof pick?.harness === "string" && typeof pick.model === "string" && pick.harness !== "" && pick.model !== ""
  );
}

function read(): Stored {
  try {
    const parsed: unknown = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "{}");
    if (!parsed || typeof parsed !== "object") return {};
    const { global, folders } = parsed as Stored;
    return {
      ...(isPick(global) ? { global } : {}),
      folders: Object.fromEntries(Object.entries(folders ?? {}).filter((entry) => isPick(entry[1]))),
    };
  } catch {
    return {};
  }
}

/// Remembers `pick` for every folder and for `folder`. The agent's own "default" is not a pick.
export function rememberPick(pick: LastPick, folder?: string): void {
  if (!isPick(pick) || isDefaultChoice({ id: pick.model })) return;
  try {
    const stored = read();
    const folders = { ...stored.folders };
    if (folder) {
      delete folders[folder];
      folders[folder] = pick;
    }
    const kept = Object.entries(folders).slice(-MAX_FOLDERS);
    globalThis.localStorage?.setItem(
      STORAGE_KEY,
      JSON.stringify({ global: pick, folders: Object.fromEntries(kept) } satisfies Stored),
    );
  } catch {
    // Storage unavailable: the next new chat starts on the harness's own default.
  }
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
