// The New Tab page's Hybrid control (Leo, 2026-11-23 10:58Z: "somewhere in teh composer area, either below
// it or slightly above it both in a chat and in the new tab page"). Before a chat exists it has no `place`
// to pin, so the control draws the page's own Where pick and writes through it: Hybrid is Auto (the
// daemon's `_acpmux/place_chat`, acpmux `place_mode::decide`, says where Send starts it), Only in Cloud is
// the Cloud run mode, Only on This Mac is this Mac's. The started chat keeps that place.
import type { RunMode } from "../sandboxRun";
import type { HybridPin } from "./hybridModel";

/// The Where state the page holds for its next new chat.
export type NewTabWhere = { autoPicked: boolean; mode: RunMode };

/// The pin the control draws for the page's pick: Auto is Hybrid, Cloud is Only in Cloud, any other
/// run mode (this Mac's own, or Sandboxed, which runs here) is Only on This Mac.
export function newTabPin(where: NewTabWhere): HybridPin {
  if (where.autoPicked) return "auto";
  return where.mode === "cloud" ? "cloud" : "local";
}

/// The Where writes a pick makes, through the page's own handlers (the Where menu's rows).
export type NewTabWhereWrites = { pickAuto(on: boolean): void; onMode(mode: RunMode): void };

export function pickNewTabPin(pin: HybridPin, writes: NewTabWhereWrites): void {
  if (pin === "auto") {
    writes.pickAuto(true);
    return;
  }
  writes.pickAuto(false);
  writes.onMode(pin === "cloud" ? "cloud" : "persistent");
}
