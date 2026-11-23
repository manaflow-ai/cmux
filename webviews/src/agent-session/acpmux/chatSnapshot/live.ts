// The live page's side of a chat's snapshot (shared.ts): it tells the host the chat is on screen as
// soon as the bundle runs, takes over from the copy in one frame once it drew the chat itself, and
// writes the copy the next launch draws (capture.ts), from the visible window only.
import { captureMiss, captureSnapshot } from "./capture";
import { liveMatchesCopy, noteSwap, swapDiff } from "./swapDiff";
import {
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_LIVE_GLOBAL,
  SNAPSHOT_MISS_GLOBAL,
  SNAPSHOT_SHOWN_GLOBAL,
  type SnapshotLive,
} from "./shared";
import { watchLaunchSettle } from "../launchSettle";

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
/// `sizes`: the last few writes' viewport, page visibility and cause ("868x712 visible quiet"), newest
/// last, so a copy refused on size at the next launch names which write left it.
const writes = { count: 0, last: "none" as string, sizes: [] as string[] };
const WRITE_SIZES_KEPT = 6;

/// The chat's copy as this document saw it, for `debug.agent_pane layout_watch` and the chat-open
/// trace: when it drew and the live page took over, else why nothing drew and why the host served
/// none; and the page's writes.
export function chatSnapshotReport(): Record<string, unknown> {
  const globals = (typeof window === "undefined" ? {} : window) as unknown as Record<string, unknown>;
  return {
    ...chatSnapshotTimes(),
    miss: globals[SNAPSHOT_MISS_GLOBAL] ?? null,
    served: globals[`${SNAPSHOT_GLOBAL}Why`] ?? null,
    served_cause: (globals[SNAPSHOT_GLOBAL] as { cause?: unknown } | undefined)?.cause ?? null,
    writes: { ...writes, sizes: [...writes.sizes] },
    view: typeof window === "undefined" ? null : `${Math.round(window.innerWidth)}x${Math.round(window.innerHeight)}`,
    swap_diff: swapDiff() ?? null,
  };
}

/// The live page shows and the copy goes, in the same task, so the frame after shows the live page
/// and no frame shows both or neither. `doc` is the page's document.
export function removeChatSnapshot(doc: Document = document, held?: { ms: number; matched: boolean }): boolean {
  // The copy's input watch (``reportChatSnapshot``) ends with the copy, however it goes.
  stopCopyInput?.();
  stopCopyInput = undefined;
  const host = doc.querySelector(SNAPSHOT_HOST_TAG);
  const root = doc.getElementById("root");
  if (root) root.style.removeProperty("opacity");
  if (!host) return false;
  if (host.shadowRoot && root && doc.defaultView) noteSwap(host.shadowRoot, root, doc.defaultView, held);
  host.remove();
  const value = shown();
  if (value) value.swappedAt = performance.now();
  performance.mark?.("cmux-chat:snapshot-swap");
  return true;
}

/// The longest the swap waits for the live page to lay out what the copy shows (``swapChatSnapshot``).
/// A part the copy has and the live page never draws (an ask answered since) keeps it no longer.
const SWAP_MATCH_MS = 600;

/// Takes over from the copy once the live page lays out what the copy shows (swapDiff.ts
/// `liveMatchesCopy`), at most ``SWAP_MATCH_MS`` after the page drew the chat: the live page renders
/// under the copy, and removing the copy before a frame paints shows it in one step. Swapped at the
/// first frame, a part the host answers after the chat is read (a folder's trust ask, 91 px over the
/// composer) came in 50 ms later and drew every row up by its height, after each relaunch (relaunch-shift
/// bench; Leo, 2026-11-14: "too much render shift when the thing restarts to update").
export function swapChatSnapshot(): void {
  // A copy the host answers after this draws nothing (boot.ts): the page shows the chat itself.
  if (typeof window !== "undefined") liveSide().drawn = true;
  if (!showsChatSnapshot()) return;
  const start = performance.now();
  const step = () => {
    const host = document.querySelector(SNAPSHOT_HOST_TAG);
    // Gone already: a press ended it (``reportChatSnapshot``).
    if (!host) return;
    const root = document.getElementById("root");
    const waited = performance.now() - start;
    const matched = !host.shadowRoot || !root || liveMatchesCopy(host.shadowRoot, root);
    if (!matched && waited < SWAP_MATCH_MS) {
      requestAnimationFrame(step);
      return;
    }
    removeChatSnapshot(document, { ms: waited, matched });
  };
  requestAnimationFrame(step);
}

/// How long the live page may take to draw the chat before the copy goes anyway, so a page that
/// never draws one never keeps an old frame up. Past the page's own bounds for its first paint: a
/// quiet failed handshake is said after hostRetry.ts HOST_ERROR_DEADLINE_MS (25 s, while acpmux
/// restarts after an update), and an attach is waited on for App.tsx CHAT_DRAW_HOLD_MS (10 s)
/// after the handshake. At 10 s the copy went while acpmux was still starting, and the pane went
/// blank until the chat came (Leo, 2026-11-09: "flickered in and out").
const SNAPSHOT_HOLD_MS = 40_000;

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

/// Swallows the rest of the key press that ended the copy: its repeats and its release reach
/// nothing, so holding Enter never sends from the composer under the copy. Ends at the key's
/// release, or when the window loses focus (the release then never comes).
function swallowKey(code: string): void {
  const swallow = (event: Event) => {
    if ((event as KeyboardEvent).code !== code) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.type === "keyup") done();
  };
  const done = () => {
    for (const name of ["keydown", "keypress", "keyup"]) window.removeEventListener(name, swallow, true);
    window.removeEventListener("blur", done);
  };
  for (const name of ["keydown", "keypress", "keyup"]) window.addEventListener(name, swallow, { capture: true });
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
    // The copy is the page's first paint: what moves from here is the launch's settle (launchSettle.ts).
    watchLaunchSettle(report, SNAPSHOT_HOST_TAG);
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
        else if (event.type === "keydown") swallowKey((event as KeyboardEvent).code);
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
/// drawn again under the same one, or another of the same appearance (shared.ts `fitsDocument`).
let chatTheme = "";
export function noteChatTheme(key: unknown): void {
  if (typeof key === "string") chatTheme = key;
}

/// The quiet the transcript keeps before a write, and the least time between two writes: a
/// streaming reply writes at most once per ``WRITE_GAP_MS``, never per frame or per delta.
const QUIET_MS = 1_500;
const WRITE_GAP_MS = 10_000;
/// How long a resize rests before the copy is written at the new size (``watchChatSnapshot``).
const RESIZE_QUIET_MS = 400;
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
  const write = (cause: string) => {
    timer = undefined;
    // No theme heard yet: nothing to key a copy by, and the one kept stays.
    if (stopped || !chatTheme) return;
    const snapshot = captureSnapshot(doc, chatTheme);
    wroteAt = performance.now();
    // Too large to keep (or no chat drawn): the host forgets the older one, which no longer shows
    // what this chat is, and keeps why, which the next document's record reads.
    writes.count += 1;
    writes.sizes.push(`${Math.round(view.innerWidth)}x${Math.round(view.innerHeight)} ${doc.visibilityState} ${cause}`);
    if (writes.sizes.length > WRITE_SIZES_KEPT) writes.sizes.shift();
    const miss = captureMiss();
    // A miss carries when it was taken too, so the host orders it with the copies (`savedAt`).
    // `cause` rides along (the host keeps the copy opaque) so the next document's record names the
    // write that left the copy it got.
    void put(
      snapshot ? { sessionId, ...snapshot, cause: writes.sizes.at(-1) } : { sessionId, miss, savedAt: Date.now() },
    ).then(
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
        else write("quiet");
      },
      Math.max(0, due),
    );
  };
  // A change moves the armed timer to its new due time, so the page wakes once when it has been quiet, never to
  // find it changed and arm again (that re-arm woke a chat at rest after a switch, bench/chat-switch.bench.ts
  // idle_wakeups). One MutationObserver callback per batch of changes: a clear and a set, no wakeup.
  const changed = () => {
    changedAt = performance.now();
    if (timer !== undefined) view.clearTimeout(timer);
    timer = undefined;
    schedule();
  };
  const observer = new view.MutationObserver(changed);
  observer.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
  // A resize can change no markup (the rows and composer follow the viewport in CSS), and a copy is
  // drawn only at the size it was written at (shared.ts `fitsDocument`): a pane resized after the
  // last write left a copy the next launch refused ("size 868x712, drawn at 528x512" in the
  // relaunch-shift bench), and the chat opened from nothing, its chips filling in after the attach.
  // So a resize writes once it rests, ``RESIZE_QUIET_MS``, past the write gap: a quit within the gap
  // (the host asks for a write only when the tab hides) kept the old size.
  let resizeTimer: number | undefined;
  const resized = () => {
    if (stopped) return;
    view.clearTimeout(resizeTimer);
    resizeTimer = view.setTimeout(() => {
      resizeTimer = undefined;
      if (timer !== undefined) view.clearTimeout(timer);
      write("resize");
    }, RESIZE_QUIET_MS);
  };
  view.addEventListener("resize", resized);
  const now = (cause: string) => {
    if (timer !== undefined) view.clearTimeout(timer);
    write(cause);
  };
  const hidden = () => {
    if (doc.visibilityState === "hidden") now("hidden");
  };
  const asked = () => now("asked");
  doc.addEventListener("visibilitychange", hidden);
  view.addEventListener(SNAPSHOT_WRITE_EVENT, asked);
  changedAt = performance.now();
  wroteAt = -WRITE_GAP_MS;
  schedule();
  return () => {
    stopped = true;
    observer.disconnect();
    view.removeEventListener("resize", resized);
    view.clearTimeout(resizeTimer);
    if (timer !== undefined) view.clearTimeout(timer);
    doc.removeEventListener("visibilitychange", hidden);
    view.removeEventListener(SNAPSHOT_WRITE_EVENT, asked);
  };
}
