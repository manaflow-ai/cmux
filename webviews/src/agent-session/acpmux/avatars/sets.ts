// The built-in animated avatar sets (`cmux-avatar/1`, format.ts), each drawn by code into a 32 px
// pixel-art sheet with six state rows facing right: Captain (drawn in this lane), and Sprout, Bolt and
// Mochi (each drawn by its own Codex session). They sit next to the Chief Dock's nine still mascots.
// Imported, not `new URL(..., import.meta.url)`: the shipped pages inline each PNG as a data URL.
import { parseAvatarManifest, sheetSize, type AvatarManifest } from "./format";
import bolt from "./sets/bolt/avatar.json";
import boltSheet from "./sets/bolt/sheet.png";
import captain from "./sets/captain/avatar.json";
import captainSheet from "./sets/captain/sheet.png";
import mochi from "./sets/mochi/avatar.json";
import mochiSheet from "./sets/mochi/sheet.png";
import sprout from "./sets/sprout/avatar.json";
import sproutSheet from "./sets/sprout/sheet.png";

/** A manifest with its sheet's URL and the sheet's real size in px (it may be larger than the manifest needs). */
export type AvatarSet = { manifest: AvatarManifest; sheet: string; size: { width: number; height: number } };

/** `width` x `height`: the sheet PNG's own size in px (format.test.ts reads each PNG and compares). */
const load = (json: unknown, sheet: string, width: number, height: number): AvatarSet => {
  const parsed = parseAvatarManifest(json);
  if ("error" in parsed) throw new Error(`built-in avatar set: ${parsed.error}`);
  const need = sheetSize(parsed.manifest);
  if (width < need.width || height < need.height)
    throw new Error(`built-in avatar set: ${parsed.manifest.id}'s sheet is too small`);
  return { manifest: parsed.manifest, sheet, size: { width, height } };
};

/** Mochi first: the pick of the four (the most readable at pet size, and the warmest motion). */
export const AVATAR_SETS: readonly AvatarSet[] = [
  load(mochi, mochiSheet, 256, 192),
  load(captain, captainSheet, 192, 192),
  load(sprout, sproutSheet, 256, 192),
  load(bolt, boltSheet, 192, 192),
];

export const avatarSet = (id: string): AvatarSet | undefined => AVATAR_SETS.find((set) => set.manifest.id === id);
