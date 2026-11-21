// The reader focusing the chat while something waits on them to look (Leo, 2026-11-21: "if i click
// into the app or click into you for the workspace like focus anything the composer just the window
// the pane it should fade away"). One watcher for every surface that says "the person is at this
// chat now", so the "New" line (SinceDivider.tsx) and anything else that should go once they are
// back read the same signal:
//
// - `window`: the app or its window became key, or the pane's web view took the keyboard (the
//   window's `focus`, which a cmux pane's web view gets as its pane is focused).
// - `focus`: something in the page took focus: the composer, a control in the chat, or the host's
//   focusContent, which puts the keyboard in the composer (composerFocus.ts).
// - `press`: a click or tap anywhere in the page: into the transcript, the pane, the chat.
//
// The workspace or tab being shown starts the reader's look rather than ending it: what drew the
// line on that return (direct.ts `showChanged`, `markSeen`) must stay on screen long enough to be
// read. A signal counts only once the page has been shown for `READER_FOCUS_SETTLE_MS` since the
// watch began or the page was last shown, so the activation that brought the reader here (its
// window focus, the composer's claim 120 ms later) never takes the line away before it is seen; the
// reader's next focus does. Shown or not is read from the page's one projection of "the person is
// at this page" (pageKey.ts `watchPageKey`), with no visibility listener of its own.
import { useEffect, useEffectEvent } from "react";
import { watchPageKey } from "../pageKey";

export type ReaderFocusSource = "window" | "focus" | "press";

/// How long the page must have been shown before a focus counts: longer than the activation that
/// shows it (window focus, then the composer's claim after ACTIVATION_SETTLE_MS, composerFocus.ts),
/// short enough that the reader's own next click always counts.
export const READER_FOCUS_SETTLE_MS = 1_000;

type FocusWindow = Pick<Window, "addEventListener" | "removeEventListener">;
type FocusDocument = Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;

export type ReaderFocusOptions = {
  win?: FocusWindow;
  doc?: FocusDocument;
  now?: () => number;
  settleMs?: number;
  /// The page-key projection's watch (pageKey.ts); tests pass their own.
  watchKey?: (run: () => void) => () => void;
};

/// Calls `run` each time the reader focuses this page (the window, the pane, the chat or the
/// composer) after it has been shown for the settle time. Returns the unwatch.
export function watchReaderFocus(
  run: (source: ReaderFocusSource) => void,
  {
    win = typeof window === "undefined" ? undefined : window,
    doc = typeof document === "undefined" ? undefined : document,
    now = () => performance.now(),
    settleMs = READER_FOCUS_SETTLE_MS,
    watchKey = (onKey) => watchPageKey(onKey),
  }: ReaderFocusOptions = {},
): () => void {
  if (!win || !doc) return () => undefined;
  const shown = () => doc.visibilityState !== "hidden";
  let shownAt: number | undefined = shown() ? now() : undefined;
  /// Hidden ends the look; shown again starts a new one.
  const sample = () => {
    if (!shown()) shownAt = undefined;
    else shownAt ??= now();
  };
  const signal = (source: ReaderFocusSource) => () => {
    sample();
    if (shownAt === undefined || now() - shownAt < settleMs) return;
    run(source);
  };
  const onWindow = signal("window");
  const onFocus = signal("focus");
  const onPress = signal("press");
  const stopKey = watchKey(sample);
  win.addEventListener("focus", onWindow);
  doc.addEventListener("focusin", onFocus, true);
  doc.addEventListener("pointerdown", onPress, true);
  return () => {
    stopKey();
    win.removeEventListener("focus", onWindow);
    doc.removeEventListener("focusin", onFocus, true);
    doc.removeEventListener("pointerdown", onPress, true);
  };
}

/// `watchReaderFocus` while `enabled`, from the commit on: the watch starts when the component that
/// waits on the reader mounts, so the settle time runs from when it was first drawn.
export function useReaderFocus(run: (source: ReaderFocusSource) => void, enabled = true): void {
  const onFocus = useEffectEvent(run);
  useEffect(() => {
    if (!enabled) return;
    return watchReaderFocus((source) => onFocus(source));
  }, [enabled]);
}
