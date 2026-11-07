// The live page's side of a chat's snapshot (shared.ts): it tells the host the chat is on screen as
// soon as the bundle runs, takes over from the copy in one frame once it drew the chat itself, and
// writes the copy the next launch draws (capture.ts), from the visible window only.
import { captureSnapshot } from "./capture";
import { SNAPSHOT_HOST_TAG, SNAPSHOT_SHOWN_GLOBAL } from "./shared";

type Shown = { at: number; swappedAt?: number };

function shown(): Shown | undefined {
  if (typeof window === "undefined") return undefined;
  const value = (window as unknown as Record<string, unknown>)[SNAPSHOT_SHOWN_GLOBAL] as Shown | undefined;
  return value && typeof value.at === "number" ? value : undefined;
}

/// Whether the boot script drew a snapshot this document still shows.
export function showsChatSnapshot(): boolean {
  return !!shown() && typeof document !== "undefined" && !!document.querySelector(SNAPSHOT_HOST_TAG);
}

/// When the snapshot drew and when the live page took over, in `performance.now()` time (layoutWatch.ts).
export function chatSnapshotTimes(): { painted_ms: number; swapped_ms: number | null } | undefined {
  const value = shown();
  if (!value) return undefined;
  return {
    painted_ms: Math.round(value.at),
    swapped_ms: value.swappedAt === undefined ? null : Math.round(value.swappedAt),
  };
}

/// The live page shows and the copy goes, in the same task, so the frame after shows the live page
/// and no frame shows both or neither. `doc` is the page's document.
export function removeChatSnapshot(doc: Document = document): boolean {
  const host = doc.querySelector(SNAPSHOT_HOST_TAG);
  const root = doc.getElementById("root");
  if (root) root.style.removeProperty("opacity");
  if (!host) return false;
  host.remove();
  const value = shown();
  if (value) value.swappedAt = performance.now();
  performance.mark?.("cmux-chat:snapshot-swap");
  return true;
}

/// Takes over from the copy at the next frame: the live page's frame is in by then (it rendered
/// under the copy), and removing the copy before that frame paints shows it in one step.
export function swapChatSnapshot(): void {
  if (!showsChatSnapshot()) return;
  requestAnimationFrame(() => removeChatSnapshot());
}

/// How long the live page may take to draw the chat before the copy goes anyway: the page's own
/// bound for its first paint (App.tsx CHAT_DRAW_HOLD_MS), so a page that never draws one never
/// keeps an old frame up.
const SNAPSHOT_HOLD_MS = 10_000;

/// Called as the bundle starts: when the copy shows, the host shows the page now, in one frame and
/// with no fade, as for a kept tail (AgentPaneView+Loading `endLoadingState`).
export function reportChatSnapshot(
  report: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): void {
  if (!showsChatSnapshot()) return;
  void report("pane.painted", { drewKeptTail: true }).catch(() => undefined);
  // Input before the swap reaches the live page under the copy; a click or key also ends the copy,
  // so what it does shows. Stops with the copy.
  const end = () => {
    removeChatSnapshot();
    stop();
  };
  const timer = window.setTimeout(end, SNAPSHOT_HOLD_MS);
  const events = ["pointerdown", "keydown", "wheel"] as const;
  const stop = () => {
    window.clearTimeout(timer);
    for (const name of events) window.removeEventListener(name, end, true);
  };
  for (const name of events) window.addEventListener(name, end, { capture: true, passive: true });
}

/// The quiet the transcript keeps before a write, and the least time between two writes: a
/// streaming reply writes at most once per ``WRITE_GAP_MS``, never per frame or per delta.
const QUIET_MS = 1_500;
const WRITE_GAP_MS = 10_000;
/// The host event that asks for a write now (the tab was hidden; AgentPaneView+PageHost).
export const SNAPSHOT_WRITE_EVENT = "cmux-chat-snapshot-write";

/// Keeps chat `sessionId`'s snapshot current while this page shows it: after the page went quiet
/// (no change in ``QUIET_MS``, writes ``WRITE_GAP_MS`` apart), when the page is hidden, and when the
/// host asks. Returns the stop, which also ends the watch's observer and timer.
export function watchChatSnapshot(
  sessionId: string,
  put: (params: Record<string, unknown>) => Promise<unknown>,
  doc: Document = document,
): () => void {
  const root = doc.getElementById("root");
  const view = doc.defaultView;
  if (!root || !view) return () => {};
  let timer: number | undefined;
  let changedAt = 0;
  let wroteAt = 0;
  let stopped = false;
  const write = () => {
    timer = undefined;
    if (stopped) return;
    const snapshot = captureSnapshot(doc);
    wroteAt = performance.now();
    // Too large to keep (or no chat drawn): the host forgets the older one, which no longer shows
    // what this chat is.
    void put(snapshot ? { sessionId, ...snapshot } : { sessionId }).catch(() => undefined);
  };
  const schedule = () => {
    if (timer !== undefined || stopped) return;
    const now = performance.now();
    const due = Math.max(changedAt + QUIET_MS, wroteAt + WRITE_GAP_MS) - now;
    timer = view.setTimeout(
      () => {
        timer = undefined;
        const late = Math.max(changedAt + QUIET_MS, wroteAt + WRITE_GAP_MS) - performance.now();
        if (late > 1) schedule();
        else write();
      },
      Math.max(0, due),
    );
  };
  const observer = new view.MutationObserver(() => {
    changedAt = performance.now();
    schedule();
  });
  observer.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
  const now = () => {
    if (timer !== undefined) view.clearTimeout(timer);
    write();
  };
  const hidden = () => {
    if (doc.visibilityState === "hidden") now();
  };
  doc.addEventListener("visibilitychange", hidden);
  view.addEventListener(SNAPSHOT_WRITE_EVENT, now);
  changedAt = performance.now();
  wroteAt = -WRITE_GAP_MS;
  schedule();
  return () => {
    stopped = true;
    observer.disconnect();
    if (timer !== undefined) view.clearTimeout(timer);
    doc.removeEventListener("visibilitychange", hidden);
    view.removeEventListener(SNAPSHOT_WRITE_EVENT, now);
  };
}
