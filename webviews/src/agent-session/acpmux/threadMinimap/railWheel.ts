// The compact rail scrolls its own list once its prompts outgrow its height (design/session-rail.md,
// "Height and overflow"). The wheel over that list is the rail's: it scrolls the list and never the
// transcript, and it is not the reader moving the transcript either (no follow release, no glide).
// A rail that fits its prompts carries no mark, and the wheel over it reaches the transcript as before.

/// Set on the rail's list while it overflows and so scrolls itself (threadMinimap.css keys its
/// `overflow-y` on it, so a list that fits is not a scroll container and never takes the wheel).
export const RAIL_SCROLLS_ATTRIBUTE = "data-rail-scrolls";

/// Whether `event` is a wheel over a rail list that scrolls itself. The transcript's capture-phase
/// input listeners run before any listener on the rail can stop the event, so they ask this first.
export function railOwnsWheel(event: Event): boolean {
  if (event.type !== "wheel") return false;
  const target = event.target as Element | null;
  return typeof target?.closest === "function" && target.closest(`[${RAIL_SCROLLS_ATTRIBUTE}]`) !== null;
}
