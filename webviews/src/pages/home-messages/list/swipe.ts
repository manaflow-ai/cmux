// A row's two-finger horizontal swipe, ported from the native list (MessagesLab's SidebarView "Swipe
// actions"): the row slides and shows its actions behind it. Swipe right shows Mark as Read or
// Unread, swipe left Delete. Past 60 % of the width the edge action runs on release; past half the
// buttons the row stays open; else it closes. A click on a button runs it; any other press or a
// vertical scroll closes the row. Pure: the list feeds it the wheel's steps and the gesture's end.

/** One action behind a row. */
export type SwipeAction = "read" | "unread" | "delete";

/** Each open button's width (the native `swipeButtonWidth`). */
export const SWIPE_BUTTON = 74;
/** Past this share of the row's width the edge action runs on release. */
export const SWIPE_FULL = 0.6;
/** The wheel's quiet time that ends a gesture (Chromium sends no phases for a trackpad swipe). */
export const SWIPE_END_MS = 120;

export interface SwipeState {
  id: string;
  /** The row's offset: right positive (the leading actions), left negative (the trailing ones). */
  offset: number;
  /** Settled open on its buttons (a release left it there). */
  open: boolean;
}

export interface SwipeActions {
  leading: readonly SwipeAction[];
  trailing: readonly SwipeAction[];
}

/** The actions a row offers: Read or Unread on the left (Unread only where marks are kept), Delete on the right. */
export function swipeActions(unread: boolean, canMark: boolean, canDelete: boolean): SwipeActions {
  return {
    leading: unread ? ["read"] : canMark ? ["unread"] : [],
    trailing: canDelete ? ["delete"] : [],
  };
}

/** The row moved by `dx` (fingers right positive): a side with no actions does not move. */
export function swipeBy(state: SwipeState, dx: number, width: number, actions: SwipeActions): SwipeState {
  let offset = state.offset + dx;
  if (offset > 0 && actions.leading.length === 0) offset = 0;
  if (offset < 0 && actions.trailing.length === 0) offset = 0;
  offset = Math.max(-width, Math.min(width, offset));
  return { ...state, offset, open: false };
}

/** The gesture ended: the row settles open, closed, or runs its edge action (`run`). */
export function swipeEnd(
  state: SwipeState,
  width: number,
  actions: SwipeActions,
): { state: SwipeState | null; run?: SwipeAction } {
  const side = state.offset > 0 ? actions.leading : actions.trailing;
  const n = side.length;
  if (n > 0 && Math.abs(state.offset) >= width * SWIPE_FULL) {
    // The edge action: the leading side's first, the trailing side's last (Delete).
    const run = state.offset > 0 ? side[0] : side[n - 1];
    return { state: null, ...(run ? { run } : {}) };
  }
  if (n > 0 && Math.abs(state.offset) >= (n * SWIPE_BUTTON) / 2)
    return { state: { ...state, offset: Math.sign(state.offset) * n * SWIPE_BUTTON, open: true } };
  return { state: null };
}
