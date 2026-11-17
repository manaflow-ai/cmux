// The room under the transcript's header for the pinned section (Needs you) and, under it, the Set
// Up cmux card. Ported from the native HomeNativeTranscriptView+PinnedSection.swift
// `layoutPinnedSection`: both stop above the message box; a pinned section taller than the room gives
// way and clips, leaving the card at least its title and a row (120 px, or its whole height when
// shorter); a card taller than what is left scrolls inside its slot. The transcript's top room grows
// by what they take, so the oldest message scrolls clear of them.

/** The least of the card's height a pinned section leaves it: its title and a row; the rest scrolls. */
export const SETUP_CARD_MIN_HEIGHT = 120;
/** The space between the pinned section and the card, and between them and the message box. */
export const PINNED_GAP = 8;

export interface PinnedLayout {
  /** The pinned section's shown height (0: no room, or none). */
  pinned: number;
  /** The card's shown height (0: none, or not measured yet). */
  card: number;
}

/**
 * `room`: the height from the pinned area's top to the message box; `pinned` and `card`: their
 * natural heights, undefined when absent. Unmeasured (0) parts take no room but stay mounted, so
 * they measure.
 */
export function pinnedLayout(room: number, pinned: number | undefined, card: number | undefined): PinnedLayout {
  const space = Math.max(0, room - PINNED_GAP);
  const floor = card ? Math.min(card, SETUP_CARD_MIN_HEIGHT) : 0;
  const shownPinned = pinned ? Math.min(pinned, Math.max(0, space - (floor > 0 ? floor + PINNED_GAP : 0))) : 0;
  const top = shownPinned > 0 ? shownPinned + PINNED_GAP : 0;
  const shownCard = card ? Math.min(card, Math.max(0, space - top)) : 0;
  return { pinned: shownPinned, card: shownCard };
}
