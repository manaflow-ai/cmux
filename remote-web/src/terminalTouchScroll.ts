export type TerminalTouchScrollState = {
  lastPageY: number | null;
};

export type ScrollableViewport = {
  scrollTop: number;
};

export function createTerminalTouchScrollState(): TerminalTouchScrollState {
  return { lastPageY: null };
}

export function beginTerminalTouchScroll(state: TerminalTouchScrollState, pageY: number) {
  state.lastPageY = pageY;
}

export function scrollTerminalViewportByTouch(
  state: TerminalTouchScrollState,
  pageY: number,
  viewport: ScrollableViewport,
) {
  if (state.lastPageY === null) {
    state.lastPageY = pageY;
    return 0;
  }

  const deltaY = state.lastPageY - pageY;
  state.lastPageY = pageY;
  if (deltaY === 0) return 0;
  viewport.scrollTop += deltaY;
  return deltaY;
}

export function endTerminalTouchScroll(state: TerminalTouchScrollState) {
  state.lastPageY = null;
}
