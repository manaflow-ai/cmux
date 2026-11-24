// The Background card's Recent strip (Leo, 2026-11-22: "i at least want the choosing between
// rotating background folders and past selected and whatever i remember i set it and then it was
// cumbersome back then to switch back"). The list is appearance.backgroundRecents, which the
// daemon's settings write keeps (cmux-config store/write.rs, newest first, at most 8), so a change
// from the CLI, the palette or this page is in it alike; the page only draws it and writes
// appearance.background on a click.
import { BACKGROUND_KEY, DYNAMIC_KEY, FOLDER_PREFIX, type WallpaperWrite } from "./wallpaperSwitch";

export const RECENTS_KEY = "appearance.backgroundRecents";

/** What a recent tile draws: a folder tile, the shuffle, no picture, a mode, or a thumbnail. */
export type RecentKind = "folder" | "shuffle" | "none" | "mode" | "picture";
export type RecentTile = { id: string; kind: RecentKind; title: string };

type Titled = { id: string; title: string };

/** A recent pick's writes: the background, and sun mode off as Switch Automatically's Off turns it,
 * so a static picture never keeps appearance.backgroundDynamic "time" (the CLI's `back` does the same). */
export function recentWrites(id: string, dynamic: unknown): WallpaperWrite[] {
  return [[BACKGROUND_KEY, id], ...(dynamic === "time" ? [[DYNAMIC_KEY, null] as const] : [])];
}

/** The kind of a background id, as the strip draws it. */
export function recentKind(id: string): RecentKind {
  if (id.startsWith(FOLDER_PREFIX)) return "folder";
  if (id === "daily") return "shuffle";
  if (id === "none") return "none";
  if (id === "appearance" || id === "schedule") return "mode";
  return "picture";
}

/** The last name of a folder: or file: path, else the id. */
export function lastName(id: string): string {
  return (
    id
      .replace(/^(folder|system|file):/, "")
      .split("/")
      .filter(Boolean)
      .at(-1) ?? id
  );
}

/** The tiles for `recents` (the row's value; anything but a string list is none), without the
 * background shown now: newest first, each once. `titles` names the pictures the picker knows and the
 * words for the shuffle, none and the modes; a folder is its name, any other picture its file name. */
export function recentTiles(
  recents: unknown,
  current: string,
  choices: readonly Titled[],
  words: Record<"shuffle" | "none" | "appearance" | "schedule", string>,
): RecentTile[] {
  if (!Array.isArray(recents)) return [];
  const seen = new Set<string>([current]);
  const tiles: RecentTile[] = [];
  for (const id of recents) {
    if (typeof id !== "string" || id === "" || seen.has(id)) continue;
    seen.add(id);
    const kind = recentKind(id);
    const title =
      kind === "folder"
        ? lastName(id)
        : kind === "shuffle"
          ? words.shuffle
          : kind === "none"
            ? words.none
            : kind === "mode"
              ? words[id as "appearance" | "schedule"]
              : (choices.find((choice) => choice.id === id)?.title ?? lastName(id));
    tiles.push({ id, kind, title });
  }
  return tiles;
}
