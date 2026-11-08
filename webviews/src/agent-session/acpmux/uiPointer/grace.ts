// Inspect Element's grace (Leo, 2026-11-08): after right-click > Inspect Element the picker holds
// the right-clicked element, not whatever lies under the menu row the pointer chose. The hold lasts
// while the person has not really moved: the first pointer position after the menu closes (down on
// the menu row, wherever that was) is the origin, and the hold ends only once both the grace time
// has passed and the pointer is a deliberate distance from that origin. Then ordinary hover-picking
// follows the pointer again. Time comes from the caller (event time or a test clock), never a timer.

/** How long the right-clicked element holds, whatever the pointer does. */
export const UI_POINTER_GRACE_MS = 500;
/** How far from its first post-menu position the pointer must move to leave the held element. */
export const UI_POINTER_MOVE_PX = 16;

export type UiPointerGrace = {
  /** When Inspect Element started the hold. */
  since: number;
  /** The pointer's first position after the hold started; unset until the first move. */
  origin?: { x: number; y: number };
};

export const startGrace = (now: number): UiPointerGrace => ({ since: now });

/**
 * One pointer move during a hold: the hold as it continues, or null once the move releases it
 * (grace time passed and the pointer is `UI_POINTER_MOVE_PX` or more from its origin).
 */
export function graceAfterMove(grace: UiPointerGrace, now: number, x: number, y: number): UiPointerGrace | null {
  const origin = grace.origin ?? { x, y };
  const moved = Math.hypot(x - origin.x, y - origin.y);
  if (now - grace.since >= UI_POINTER_GRACE_MS && moved >= UI_POINTER_MOVE_PX) return null;
  return grace.origin ? grace : { ...grace, origin };
}
