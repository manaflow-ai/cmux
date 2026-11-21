/// The longest a New Tab field's readiness waits for its page to get focus. The app holds every key
/// typed after Cmd-T until the readiness comes, so this wait only delays when those keys show; past
/// it the readiness goes anyway (a page the app focuses only at the readiness never waits longer).
export const INPUT_READY_FOCUS_WAIT_MS = 300;

/// Reports a New Tab field's readiness (`report`) once its page has focus: at once when `view`'s
/// document has it, else at the window's next `focus` event, or after `waitMs`.
///
/// The app replays the keys typed after Cmd-T into the page as soon as the readiness comes. A
/// Chromium page that was shown a moment ago is often not focused yet: its renderer dropped every
/// replayed key, and after a cold launch Cmd-T then "hello" left the field empty, about one try in
/// five (cmux-lawrence-2, 2026-11-11). Focused, the same page took all five keys.
///
/// Returns a cancel function; after it runs, `report` never runs.
export function reportInputReadyWhenFocused(
  view: Window | null | undefined,
  report: () => void,
  waitMs: number = INPUT_READY_FOCUS_WAIT_MS,
): () => void {
  if (!view || view.document.hasFocus()) {
    report();
    return () => {};
  }
  let done = false;
  const fire = () => {
    if (done) return;
    done = true;
    view.removeEventListener("focus", fire);
    clearTimeout(timer);
    report();
  };
  view.addEventListener("focus", fire);
  const timer = setTimeout(fire, waitMs);
  return () => {
    done = true;
    view.removeEventListener("focus", fire);
    clearTimeout(timer);
  };
}
