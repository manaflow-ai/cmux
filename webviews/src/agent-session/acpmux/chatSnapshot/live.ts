// The live page's side of a chat's snapshot (shared.ts): it tells the host the chat is on screen as
// soon as the bundle runs, takes over from the copy in one frame once it drew the chat itself, and
// writes the copy the next launch draws (capture.ts), from the visible window only.
import { slackTimersFor } from "../../../pages/shared/slackTimers";
import { captureMiss, captureSnapshot } from "./capture";
import { liveComposerTakes, watchLiveComposer } from "./liveComposer";
import { liveMatchesCopy, noteSwap, swapDiff } from "./swapDiff";
import {
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_LIVE_GLOBAL,
  SNAPSHOT_MISS_GLOBAL,
  SNAPSHOT_SHOWN_GLOBAL,
  TRANSCRIPT_ROWS_RELEASED_ATTRIBUTE,
  type SnapshotLive,
} from "./shared";
import { watchLaunchSettle } from "../launchSettle";
import { COMPOSER_READY_EVENT } from "../composerFocus";
import { skeletonField } from "./skeleton";
import { focusRoute } from "../../../ui/focusRoute";
import { LIVE_THINKING } from "../conversation/turns";

/// `hold`: how the wait for the chat's draft ran out (draftSettleHold.ts), when, and at a `cap`
/// what still differed between the copy's composer and the live one (`composerDifference`).
type Shown = {
  at: number;
  composerAt?: number;
  swappedAt?: number;
  chromeOnly?: boolean;
  hold?: { by: string; at: number; differs?: string };
};

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

/// What the composer in an element shows, or undefined when it has no prompt (its editor's root; the
/// placeholder lies beside it). It holds the prompt, surrounding text, tile count, and height.
function composerShows(scope: ParentNode | null | undefined): string[] | undefined {
  const composer = scope?.querySelector(".acpmux-composer");
  const field = composer?.querySelector(".acpmux-composer-box .acpmux-md-root");
  if (!composer || !field) return undefined;
  const fold = (node: Node) => (node.textContent ?? "").replace(/\s+/g, " ").trim();
  const tiles = composer.querySelectorAll(".acpmux-attachment-slot, img, video").length;
  return [fold(field), fold(composer), String(tiles), String(Math.round(composer.getBoundingClientRect().height))];
}

const COMPOSER_PARTS = ["prompt", "text", "tiles", "height"] as const;

/// Returns a bounded description of differences between the saved and live composers.
export function composerDifference(): string | undefined {
  const copy = composerShows(document.querySelector(SNAPSHOT_HOST_TAG)?.shadowRoot);
  const live = composerShows(document.getElementById("root"));
  if (!copy || !live) return "no composer";
  const told = (part: (typeof COMPOSER_PARTS)[number], a: string, b: string) => {
    if (part === "tiles" || part === "height") return `${part} ${a}/${b}`;
    let at = 0;
    while (at < a.length && a[at] === b[at]) at += 1;
    return `${part} at ${at}, ${a.length}/${b.length} chars`;
  };
  const parts = COMPOSER_PARTS.flatMap((part, at) => (copy[at] === live[at] ? [] : [told(part, copy[at]!, live[at]!)]));
  return parts.length ? parts.join("; ") : undefined;
}

/// Whether the live page's composer shows what the copy over it shows.
export function promptMatchesChatSnapshot(): boolean {
  return showsChatSnapshot() && composerDifference() === undefined;
}

/// Records how the draft wait ended on the copy's launch record.
export function noteDraftWaitEnd(by: string): void {
  const value = shown();
  if (!value || value.hold) return;
  value.hold = { by, at: performance.now(), ...(by === "cap" ? { differs: composerDifference() ?? "none" } : {}) };
}

/// Whether the copy on screen shows a turn still running: its live line (turns.ts LIVE_THINKING),
/// which a kept tail cannot draw, since it keeps rows and not the turn's state.
export function copyShowsRunningTurn(): boolean {
  if (!showsChatSnapshot()) return false;
  const root = document.querySelector(SNAPSHOT_HOST_TAG)?.shadowRoot;
  return !!root?.querySelector(`[data-row-id="${LIVE_THINKING}"]`);
}

/// When the snapshot drew and when the live page took over, in `performance.now()` time (layoutWatch.ts).
export function chatSnapshotTimes():
  | { painted_ms: number; composer_live_ms: number | null; swapped_ms: number | null; chrome_only?: true }
  | undefined {
  const value = shown();
  if (!value) return undefined;
  return {
    painted_ms: Math.round(value.at),
    // When the live composer showed through the copy (liveComposer.ts): typing and clicks from then.
    composer_live_ms: value.composerAt === undefined ? null : Math.round(value.composerAt),
    swapped_ms: value.swappedAt === undefined ? null : Math.round(value.swappedAt),
    // Written at another size: the pane's chrome drew, the transcript's rows did not (shared.ts `fitsChromeOnly`).
    ...(value.chromeOnly ? { chrome_only: true as const } : {}),
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
    hold: shown()?.hold ?? null,
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
  // The copy's input watch (``reportChatSnapshot``) ends with the copy, however it goes, and so does
  // a takeover that waits for the live rows to fill the view (``swapChatSnapshot``).
  stopCopyInput?.();
  stopCopyInput = undefined;
  stopCoverWait?.();
  stopCoverWait = undefined;
  const host = doc.querySelector(SNAPSHOT_HOST_TAG);
  const root = doc.getElementById("root");
  if (root) root.style.removeProperty("opacity");
  if (!host) return false;
  if (host.shadowRoot && root && doc.defaultView) noteSwap(host.shadowRoot, root, doc.defaultView, held);
  host.remove();
  handOverSkeleton(doc);
  const value = shown();
  if (value) value.swappedAt = performance.now();
  performance.mark?.("cmux-chat:snapshot-swap");
  return true;
}

/// The live prompt's editable, once its editor is up (MarkdownField.tsx).
const LIVE_PROMPT = '.acpmux-composer-prompt [contenteditable="true"]';
const LIVE_PLACEHOLDER = ".acpmux-composer-prompt .acpmux-md-placeholder";
/// How long the copy's prompt field (skeleton.ts) waits for the live prompt after the swap. Past it the
/// field goes: a chat whose page drew no prompt (a question card in its place) has none to fill.
const SKELETON_WAIT_MS = 10_000;
/// The copy's prompt fields whose handover waits on the live prompt (`handOverSkeleton`).
const handingOver = new WeakSet<HTMLElement>();

/// Moves what the person typed in the copy's prompt field into the live prompt, as typing (the host's
/// `insertText`, as its queued keys go in), with the caret there when the field had it. The field stays
/// over the live prompt until that editor is up, so nothing typed meanwhile is lost. A second call while
/// one waits on the same field does nothing, so both the copy's removal and the live composer's hole
/// (#50067's `fitLiveComposer`, after it cuts the hole) may call it.
export function handOverSkeleton(doc: Document = document): void {
  const field = skeletonField(doc);
  const view = doc.defaultView;
  if (!field || !view || handingOver.has(field)) return;
  handingOver.add(field);
  let timer: number | undefined;
  let hidden: HTMLElement | null = null;
  const finish = () => {
    view.removeEventListener(COMPOSER_READY_EVENT, finish);
    view.clearTimeout(timer);
    if (hidden) hidden.style.removeProperty("visibility");
    const text = field.innerText ?? field.textContent ?? "";
    const focused = doc.activeElement === field;
    const live = doc.querySelector<HTMLElement>(LIVE_PROMPT);
    field.remove();
    if (!live || !(focused || text.length > 0)) return;
    // The person's own typing goes on in the live prompt: theirs, so a `system` move's typing guard
    // (which sees them typing in the field) does not refuse it.
    focusRoute(live, "person", "the copy's prompt field hands over to the live prompt", { preventScroll: true });
    if (text.length > 0) doc.execCommand("insertText", false, text);
  };
  if (doc.querySelector(LIVE_PROMPT)) {
    finish();
    return;
  }
  // The live placeholder under the field would show through its typed text until the handover.
  if ((field.textContent ?? "").length > 0) {
    hidden = doc.querySelector<HTMLElement>(LIVE_PLACEHOLDER);
    hidden?.style.setProperty("visibility", "hidden");
  }
  view.addEventListener(COMPOSER_READY_EVENT, finish);
  timer = view.setTimeout(finish, SKELETON_WAIT_MS);
}

/// The longest the swap waits for the live page to lay out what the copy shows (``swapChatSnapshot``).
/// A part the copy has and the live page never draws (an ask answered since) keeps it no longer.
const SWAP_MATCH_MS = 600;

/// The transcript's scroller and rows, in the live page and in the copy (capture.ts keeps both).
const SCROLLER_SELECTOR = ".acpmux-scroll";
const SHOWN_SCROLLER_SELECTOR = ".acpmux-scroll[data-cmux-shown-scroller]";
const ROW_SELECTOR = ".acpmux-row";
/// How much more empty room above the rows the live page may show than the copy did before it is a
/// step back: about a line, so a row a few pixels shorter in the live page's fonts never holds it.
const BAND_SLACK_PX = 48;

/// How far below the top of the shown transcript's view its topmost row starts, in CSS pixels: 0
/// when rows reach the view's top (or start above it), the view's height when it shows no row.
/// Undefined when `scope` (the live root, or the copy's shadow root) shows no transcript.
export function bandAboveRows(scope: ParentNode): number | undefined {
  const scroller =
    scope.querySelector<HTMLElement>(SHOWN_SCROLLER_SELECTOR) ?? scope.querySelector<HTMLElement>(SCROLLER_SELECTOR);
  if (!scroller || scroller.clientHeight === 0) return undefined;
  const view = scroller.getBoundingClientRect();
  let top = Infinity;
  for (const row of Array.from(scroller.querySelectorAll(ROW_SELECTOR))) {
    const box = row.getBoundingClientRect();
    if (box.height > 0 && box.top < top) top = box.top;
  }
  if (top === Infinity) return view.height;
  return Math.min(view.height, Math.max(0, top - view.top));
}

/// Whether the live page, taking over now, would show an empty band above its rows where the copy
/// showed rows: a kept tail cut to its byte bound inside one busy turn draws a few rows at the
/// bottom, and the older history that fills the view waits for acpmux, which an update restarts
/// (Leo, 2026-11-22, after a restart to update: "the top half of the chat blanked out for like 10
/// seconds"). False when either shows no transcript (an error, a New Tab page): that is no step back.
export function liveStepsBack(doc: Document = document): boolean {
  const copy = doc.querySelector(SNAPSHOT_HOST_TAG)?.shadowRoot;
  const root = doc.getElementById("root");
  if (!copy || !root) return false;
  const live = bandAboveRows(root);
  const drawn = bandAboveRows(copy);
  return live !== undefined && drawn !== undefined && live > drawn + BAND_SLACK_PX;
}

/// Ends a takeover waiting for the live rows to fill the view (``swapChatSnapshot``).
let stopCoverWait: (() => void) | undefined;

/// Takes over from the copy once the live page lays out what the copy shows (swapDiff.ts
/// `liveMatchesCopy`), at most ``SWAP_MATCH_MS`` after the page drew the chat: the live page renders
/// under the copy, and removing the copy before a frame paints shows it in one step. Swapped at the
/// first frame, a part the host answers after the chat is read (a folder's trust ask, 91 px over the
/// composer) came in 50 ms later and drew every row up by its height, after each relaunch (relaunch-shift
/// bench; Leo, 2026-11-14: "too much render shift when the thing restarts to update").
///
/// Then, a live page
/// whose rows do not yet reach as high as the copy's (``liveStepsBack``) keeps the copy up until they
/// do: each change of the live page is read at its next frame, and the copy goes in the frame its
/// rows fill the view (an older page landed). Input on the copy and live.ts ``SNAPSHOT_HOLD_MS`` still
/// end it, so the wait has the copy's own bound.
export function swapChatSnapshot(doc: Document = document): void {
  // A copy the host answers after this draws nothing (boot.ts): the page shows the chat itself.
  if (typeof window !== "undefined") liveSide().drawn = true;
  if (!showsChatSnapshot()) return;
  const view = doc.defaultView ?? window;
  const start = performance.now();
  // Hold until the live page lays out what the copy shows (``SWAP_MATCH_MS`` at most), one read per frame.
  const step = () => {
    const host = doc.querySelector(SNAPSHOT_HOST_TAG);
    // Gone already: a press ended it (``reportChatSnapshot``).
    if (!host) return;
    const root = doc.getElementById("root");
    const waited = performance.now() - start;
    const matched = !host.shadowRoot || !root || liveMatchesCopy(host.shadowRoot, root);
    performance.mark(`diag:swapStep matched=${matched} steps=${liveStepsBack(doc)}`);
    if (!matched && waited < SWAP_MATCH_MS) {
      view.requestAnimationFrame(step);
      return;
    }
    const held = { ms: waited, matched };
    if (!liveStepsBack(doc)) {
      removeChatSnapshot(doc, held);
      return;
    }
    if (!root || stopCoverWait) return;
    performance.mark?.("cmux-chat:snapshot-hold-band");
    let frame: number | undefined;
    const check = () => {
      frame = undefined;
      if (!liveStepsBack(doc)) removeChatSnapshot(doc, { ms: performance.now() - start, matched });
    };
    // Rows land as markup and move as style (VirtualTranscript places them absolutely): one read
    // per frame that changed anything, none while the page is at rest.
    const observer = new view.MutationObserver(() => {
      frame ??= view.requestAnimationFrame(check);
    });
    observer.observe(root, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class"] });
    const resized = () => {
      frame ??= view.requestAnimationFrame(check);
    };
    view.addEventListener("resize", resized);
    stopCoverWait = () => {
      observer.disconnect();
      view.removeEventListener("resize", resized);
      if (frame !== undefined) view.cancelAnimationFrame(frame);
    };
  };
  view.requestAnimationFrame(step);
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
    // `copy`: the inert saved copy, not the page's own paint, which reports again (AgentPaneRequest `painted`).
    void report("pane.painted", { drewKeptTail: true, copy: true }).catch(() => undefined);
    // The copy is the page's first paint: what moves from here is the launch's settle (launchSettle.ts).
    watchLaunchSettle(report, SNAPSHOT_HOST_TAG);
    // A click or key while the copy shows ends the copy and does nothing else: the live page under
    // it is at opacity 0, so a press must never act on a control the person can't see (a permission
    // card's Allow, a shortcut). The press is consumed, with the rest of its gesture (its pointerup
    // and click). A wheel ends the copy and scrolls. Stops with the copy.
    const end = (event?: Event) => {
      // The live composer showing through the copy (liveComposer.ts) takes its own typing and
      // clicks, and the copy stays; a press on another of its controls ends the copy and acts.
      const composer = event ? liveComposerTakes(event) : undefined;
      if (composer === "keep") return;
      if (composer === "reveal") {
        removeChatSnapshot();
        return stop();
      }
      // A press or key in the copy's prompt field (skeleton.ts) is the person typing: it keeps the copy.
      const field = skeletonField(document);
      if (event && field && event.target instanceof Node && field.contains(event.target)) return;
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
    const stopComposer = watchLiveComposer();
    const stop = () => {
      window.clearTimeout(timer);
      for (const name of events) window.removeEventListener(name, end, true);
      stopComposer();
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
  const slackTimers = slackTimersFor(view);
  let timer: number | undefined;
  let changedAt = 0;
  let wroteAt = 0;
  let stopped = false;
  const write = (cause: string) => {
    timer = undefined;
    // No theme heard yet: nothing to key a copy by, and the one kept stays.
    if (stopped || !chatTheme) return;
    // The last launch's copy still shows (the live rows have not filled the view yet,
    // ``swapChatSnapshot``): that copy is what the person sees and the one kept, never the live page
    // half drawn under it. The copy's going clears the root's opacity, a change the observer below
    // hears, so the write comes once the page is quiet after it.
    if (showsChatSnapshot()) return;
    // A hidden page's transcript that let go of its rows draws none: the copy written as it hid, from
    // the rows it drew then, stays the one kept until it shows again and draws them.
    if (doc.querySelector(`[${TRANSCRIPT_ROWS_RELEASED_ATTRIBUTE}]`)) return;
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
    // On the page's shared timer, up to a heartbeat late: the quiet write rides a beat instead of
    // waking a chat at rest by itself (slackTimers.ts).
    // On the beat that rests the page (`atRest`) the write goes now, ahead of QUIET_MS and WRITE_GAP_MS:
    // the page rests because nothing happened in it for a beat, so the markup is what it will stay, and a
    // timer kept for either wait would only wake it alone (the read_ahead arm's write at 3.46 s in
    // bench/chat-switch.bench.ts). A change after the rest arms the next write as before.
    timer = slackTimers.later(
      (atRest) => {
        timer = undefined;
        const late = atRest ? 0 : Math.max(changedAt + QUIET_MS, wroteAt + WRITE_GAP_MS) - performance.now();
        if (late > 1) schedule();
        else write(atRest ? "rest" : "quiet");
      },
      Math.max(0, due),
      undefined,
      { atRest: true },
    );
  };
  // A change moves the armed timer to its new due time, so the page wakes once when it has been quiet, never to
  // find it changed and arm again (that re-arm woke a chat at rest after a switch, bench/chat-switch.bench.ts
  // idle_wakeups). One MutationObserver callback per batch of changes: a clear and a set, no wakeup.
  const changed = () => {
    changedAt = performance.now();
    slackTimers.cancel(timer);
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
      slackTimers.cancel(timer);
      write("resize");
    }, RESIZE_QUIET_MS);
  };
  view.addEventListener("resize", resized);
  const now = (cause: string) => {
    slackTimers.cancel(timer);
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
    slackTimers.cancel(timer);
    doc.removeEventListener("visibilitychange", hidden);
    view.removeEventListener(SNAPSHOT_WRITE_EVENT, asked);
  };
}
