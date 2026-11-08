// The live page's side of a chat's snapshot (shared.ts): it tells the host the chat is on screen as
// soon as the bundle runs, takes over from the copy in one frame once it drew the chat itself, and
// writes the copy the next launch draws (capture.ts), from the visible window only.
import { captureMiss, captureSnapshot } from "./capture";
import {
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_LIVE_GLOBAL,
  SNAPSHOT_MISS_GLOBAL,
  SNAPSHOT_SHOWN_GLOBAL,
  type SnapshotLive,
} from "./shared";

type Shown = { at: number; swappedAt?: number };

function shown(): Shown | undefined {
  if (typeof window === "undefined") return undefined;
  const value = (window as unknown as Record<string, unknown>)[SNAPSHOT_SHOWN_GLOBAL] as Shown | undefined;
  return value && typeof value.at === "number" ? value : undefined;
}

/// The page's side the boot script reads (shared.ts `SNAPSHOT_LIVE_GLOBAL`), made on first use.
function liveSide(): SnapshotLive {
  const globals = window as unknown as Record<string, unknown>;
  const existing = globals[SNAPSHOT_LIVE_GLOBAL] as SnapshotLive | undefined;
  if (existing) return existing;
  const made: SnapshotLive = {};
  globals[SNAPSHOT_LIVE_GLOBAL] = made;
  return made;
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

/// This page's writes: how many, and what the host said to the last (`{kept}`), for the report.
const writes = { count: 0, last: "none" as string };

/// The chat's copy as this document saw it, for `debug.agent_pane layout_watch` and the chat-open
/// trace: when it drew and the live page took over, else why nothing drew and why the host served
/// none; and the page's writes.
export function chatSnapshotReport(): Record<string, unknown> {
  const globals = (typeof window === "undefined" ? {} : window) as unknown as Record<string, unknown>;
  return {
    ...chatSnapshotTimes(),
    miss: globals[SNAPSHOT_MISS_GLOBAL] ?? null,
    served: globals[`${SNAPSHOT_GLOBAL}Why`] ?? null,
    writes: { ...writes },
  };
}

/// The live page shows and the copy goes, in the same task, so the frame after shows the live page
/// and no frame shows both or neither. `doc` is the page's document.
export function removeChatSnapshot(doc: Document = document): boolean {
  // The copy's input watch (``reportChatSnapshot``) ends with the copy, however it goes.
  stopCopyInput?.();
  stopCopyInput = undefined;
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
  // A copy the host answers after this draws nothing (boot.ts): the page shows the chat itself.
  if (typeof window !== "undefined") liveSide().drawn = true;
  if (!showsChatSnapshot()) return;
  requestAnimationFrame(() => removeChatSnapshot());
}

/// How long the live page may take to draw the chat before the copy goes anyway: the page's own
/// bound for its first paint (App.tsx CHAT_DRAW_HOLD_MS), so a page that never draws one never
/// keeps an old frame up.
const SNAPSHOT_HOLD_MS = 10_000;

/// Ends the drawn copy's input watch (``reportChatSnapshot``) while one runs.
let stopCopyInput: (() => void) | undefined;

/// How long after a consumed press is released its click may still come: the click is sent in the
/// same turn as the release, so this only ends the watch when none comes (a drag off the target).
const SWALLOW_AFTER_RELEASE_MS = 100;

/// Swallows the rest of the press that ended the copy: its pointerup, mouseup and click reach
/// nothing, so the live control under the press never sees half a gesture, however long the press
/// is held. Ends at the click after the release, or shortly after a release with no click (a drag),
/// a pointercancel, or the window losing focus (the release then never comes).
function swallowGesture(): void {
  const names = ["pointerup", "mouseup", "click", "auxclick", "dblclick", "contextmenu"] as const;
  let timer: number | undefined;
  const swallow = (event: Event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.type === "click" || event.type === "auxclick") done();
    else if (event.type === "pointerup" && timer === undefined)
      timer = window.setTimeout(done, SWALLOW_AFTER_RELEASE_MS);
  };
  const done = () => {
    window.clearTimeout(timer);
    for (const name of names) window.removeEventListener(name, swallow, true);
    window.removeEventListener("pointercancel", done, true);
    window.removeEventListener("blur", done);
  };
  for (const name of names) window.addEventListener(name, swallow, { capture: true });
  window.addEventListener("pointercancel", done, { capture: true });
  window.addEventListener("blur", done);
}

/// Called as the bundle starts: when the copy shows, the host shows the page now, in one frame and
/// with no fade, as for a kept tail (AgentPaneView+Loading `endLoadingState`). The host's answer
/// loads `async` (boot.ts), so a copy may draw after this: then it reports when it draws, unless the
/// page drew the chat first.
export function reportChatSnapshot(
  report: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): void {
  if (typeof window === "undefined") return;
  const shows = () => {
    void report("pane.painted", { drewKeptTail: true }).catch(() => undefined);
    // A click or key while the copy shows ends the copy and does nothing else: the live page under
    // it is at opacity 0, so a press must never act on a control the person can't see (a permission
    // card's Allow, a shortcut). The press is consumed, with the rest of its gesture (its pointerup
    // and click). A wheel ends the copy and scrolls. Stops with the copy.
    const end = (event?: Event) => {
      // Only a press on the copy is consumed: once it is gone, input reaches the page as usual.
      if (event && event.type !== "wheel" && showsChatSnapshot()) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (event.type === "pointerdown") swallowGesture();
      }
      removeChatSnapshot();
      stop();
    };
    const timer = window.setTimeout(end, SNAPSHOT_HOLD_MS);
    const events = ["pointerdown", "keydown", "wheel"] as const;
    const stop = () => {
      window.clearTimeout(timer);
      for (const name of events) window.removeEventListener(name, end, true);
    };
    for (const name of events) window.addEventListener(name, end, { capture: true, passive: name === "wheel" });
    stopCopyInput = stop;
  };
  if (showsChatSnapshot()) shows();
  else liveSide().painted = shows;
}

/// The key of the theme the page draws in now (the host's `theme` event, pageHost.ts): a copy is
/// drawn again only under the same one (shared.ts `fitsDocument`).
let chatTheme = "";
export function noteChatTheme(key: unknown): void {
  if (typeof key === "string") chatTheme = key;
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
    // No theme heard yet: nothing to key a copy by, and the one kept stays.
    if (stopped || !chatTheme) return;
    const snapshot = captureSnapshot(doc, chatTheme);
    wroteAt = performance.now();
    // Too large to keep (or no chat drawn): the host forgets the older one, which no longer shows
    // what this chat is, and keeps why, which the next document's record reads.
    writes.count += 1;
    const miss = captureMiss();
    // A miss carries when it was taken too, so the host orders it with the copies (`savedAt`).
    void put(snapshot ? { sessionId, ...snapshot } : { sessionId, miss, savedAt: Date.now() }).then(
      (reply) => {
        const kept = (reply as { kept?: unknown } | null)?.kept;
        writes.last = !snapshot ? `forgot: ${miss}` : kept === true ? "kept" : "refused";
      },
      (error) => {
        writes.last = `error: ${String(error)}`;
      },
    );
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
