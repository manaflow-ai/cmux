// HIDDEN-REBUILD (goal chats-flat-at-any-length; Leo, 2026-11-16: "the dream is infinite chats of infinite
// length with flat or no growth in cpu/memory/even disk"). A chat page that grew live keeps what growing left
// behind: freed but held allocator pages, Blink's fragmented heap, JIT code and the per-row tables of rows it no
// longer draws. The same chat loaded fresh costs about what an empty one does (chat_100k_flat: long x1 1.10x vs
// grown x1 1.36x the empty chat's renderer memory). So a hidden chat page that took many records since its
// document started rebuilds its document: it hands its state over (the graceful swap, ../../pages/shared/
// swapHandoff.ts) and reloads. Hidden, nothing shows meanwhile, and the swapped-in document puts back its scroll,
// fields and focus owner before it is shown again.
//
// The host already lets an idle hidden chat's page go (HiddenChatPages.swift, after 10 s, warm set after 60 s).
// This sheds what the pages it keeps grew: a working chat's, a pinned tab's, the warm set's.
//
// It never rebuilds a page that holds what a reload would lose (`pageReleaseHold`: an unsent prompt, a
// selection, an open popup, an edited field), and at most once per `MIN_GAP_MS` per tab (sessionStorage), so
// a chat that keeps streaming rebuilds at most that often.

import { prepareSwap } from "../../pages/shared/swapHandoff";
import { pageReleaseHold } from "../../pages/shared/webSwap";

/** Wire frames since the document started past which a page counts as grown (a 100k-row chat grown live takes
 * ~200k; opening one fresh takes a few hundred). */
export const GROWN_FRAMES = 20_000;
/** How long a page stays hidden before it rebuilds (past the host's 10 s minimum hidden, so an idle chat's page is
 * let go first, and a look at another tab and back keeps the page). */
export const HIDDEN_REBUILD_MS = 15_000;
/** How soon a page that was held, or not yet grown, is looked at again while it stays hidden. */
export const RECHECK_MS = 15_000;
/** The least time between two rebuilds of one tab. */
export const MIN_GAP_MS = 5 * 60_000;
/** sessionStorage (it survives the reload): when this tab last rebuilt. */
export const LAST_REBUILD_KEY = "cmux.hiddenRebuild.at";

let frames = 0;

/** One wire frame reached the page (direct.ts's receive). */
export function noteWireFrame(): void {
  frames++;
}

/** Frames since the document started (tests). */
export function wireFrames(): number {
  return frames;
}

export function resetHiddenRebuild(): void {
  frames = 0;
}

export interface HiddenRebuildOptions {
  grownFrames?: number;
  hiddenMs?: number;
  recheckMs?: number;
  minGapMs?: number;
  now?: () => number;
  /** The reload itself (tests). */
  reload?: () => void;
}

/** Why the page should not rebuild now, or null when it should. */
export function rebuildBlock(doc: Document, grownFrames: number, minGapMs: number, now: number): string | null {
  if (doc.visibilityState !== "hidden") return "shown";
  if (frames < grownFrames) return "small";
  try {
    const last = Number(doc.defaultView?.sessionStorage.getItem(LAST_REBUILD_KEY) ?? 0);
    if (last && now - last < minGapMs) return "recent";
  } catch {
    return "storage";
  }
  return pageReleaseHold(doc);
}

/** Watches the page's visibility and rebuilds it once it stayed hidden and grew. Returns the uninstall. */
export function installHiddenRebuild(doc: Document = document, options: HiddenRebuildOptions = {}): () => void {
  const view = doc.defaultView;
  if (!view) return () => undefined;
  const grownFrames = options.grownFrames ?? GROWN_FRAMES;
  const hiddenMs = options.hiddenMs ?? HIDDEN_REBUILD_MS;
  const recheckMs = options.recheckMs ?? RECHECK_MS;
  const minGapMs = options.minGapMs ?? MIN_GAP_MS;
  const now = options.now ?? Date.now;
  const reload = options.reload ?? (() => view.location.reload());
  let timer: ReturnType<typeof setTimeout> | undefined;
  const clear = () => {
    if (timer !== undefined) view.clearTimeout(timer);
    timer = undefined;
  };
  const look = () => {
    timer = undefined;
    const block = rebuildBlock(doc, grownFrames, minGapMs, now());
    if (block === "shown") return;
    if (block) return void (timer = view.setTimeout(look, recheckMs));
    try {
      view.sessionStorage.setItem(LAST_REBUILD_KEY, String(now()));
    } catch {
      return;
    }
    if (!prepareSwap(doc)) return;
    console.info(`cmux.hiddenRebuild frames=${frames}`);
    reload();
  };
  const changed = () => {
    clear();
    if (doc.visibilityState === "hidden") timer = view.setTimeout(look, hiddenMs);
  };
  doc.addEventListener("visibilitychange", changed);
  changed();
  return () => {
    clear();
    doc.removeEventListener("visibilitychange", changed);
  };
}
