// A line of words that changes in place (the running turn's live line naming the call in flight),
// changing as Claude desktop's does (Leo, 2026-11-05, on its recording: "this is quite good too how
// it animates the changing text!!! we need to have that!!! for changing tool calls at the bottom"):
// the old words rise a few pixels and fade, the new ones rise in from below, and what stands after
// them on the line (the turn's clock, its counts) slides to where the new words end, so the clock
// keeps ticking while it moves.
//
// The new words are in the DOM, read and found on the commit that brings them; only paint moves.
// The old words are an inert copy (aria-hidden, inert, skipped by Find) laid over the line until
// their fade ends, which is quick: they are gone before the sliding clock crosses them, and the new
// words show only once it has mostly passed, so no two texts read over each other.
// The words' box takes its new width at once: the motion is transform and opacity only, which the
// compositor runs, so no frame restyles, lays out or paints the line again (an animated clip-path
// restyled every frame in Chromium: frame work p95 11 -> 20 ms while a reply streamed). The one
// layout read is the new width, once per change; the old width comes from a ResizeObserver, never a
// read before the commit.
//
// Short, interruptible and coalesced: a change while one plays starts from where the line is (the
// incoming words' fade and rise, the followers' offset), at most two old copies are on the line at
// once (the oldest goes), and changes inside one frame are one commit, so one change. Motion off,
// a hidden page or a zero motion token (motionMode): the new words show in one frame, with no copy.
// Reduce Motion: a crossfade, nothing moves.
//
// Stop conditions: no timer and no frame loop. Each change plays finite Web Animations (at most
// --cmux-motion-standard) that end on their own; the next change and unmount cancel them.
import { type RefObject, useLayoutEffect, useRef } from "react";
import { MOTION_EASE_OUT, MOTION_MS } from "../../motion/scale.generated";
import { motionMode } from "./motionMode";
import "./motion.css";

/// How far the words rise: the old ones up and out, the new ones up into place.
export const TEXT_SWAP_RISE_PX = 5;
/// Old copies on the line at once; a faster run of changes drops the oldest.
export const TEXT_SWAP_MAX_GHOSTS = 2;
/// Words never overlap the sliding clock legibly (Leo, 2026-11-05: overlapping text "is just the
/// worst thing ever"): the clock slides in --cmux-motion-micro, the old words are gone by this
/// fraction of theirs, and the new ones stay unseen up to this fraction of theirs.
export const TEXT_SWAP_GONE_AT = 0.5;
export const TEXT_SWAP_SHOW_FROM = 0.35;
/// The words' container: what follows them up to it slides with their width. Without it, their parent.
export const TEXT_SWAP_ROOT = "data-text-swap-root";
/// A layer over the words that fades in with the new ones instead of sliding (the shimmer's lit copy).
export const TEXT_SWAP_FADE = "data-text-swap-fade";
const GHOST = "ui-text-swap__ghost";

type SwapState = {
  element: HTMLElement | null;
  text: string | undefined;
  /// The words' laid-out width before this commit (ResizeObserver), or -1 while unknown.
  width: number;
  /// Where the words started at the last change (offsetLeft), or -1 while unknown: a mark before
  /// them (the Working line's command glyph) comes and goes with the call.
  left: number;
  /// A copy of the words as they stand, the next change's old words.
  copy: HTMLElement | null;
  /// The old copies on the line, each with its fade, cancelled when the copy goes early.
  ghosts: { element: HTMLElement; leaving?: Animation }[];
  /// The incoming words', the followers' and the fading layers' animations of the last change.
  playing: Animation[];
  observer: ResizeObserver | null;
};

const translate = (transform: string, axis: "x" | "y"): number => {
  if (!transform || transform === "none") return 0;
  const values = /matrix(?:3d)?\(([^)]*)\)/.exec(transform)?.[1]?.split(",").map(Number) ?? [];
  const value = values.length === 16 ? values[axis === "x" ? 12 : 13] : values[axis === "x" ? 4 : 5];
  return Number.isFinite(value) ? value! : 0;
};

const isHTMLElement = (element: Element): element is HTMLElement => "style" in element && "dataset" in element;

/// What stands after the words up to their container, in flow (an absolute layer stays put).
function followersOf(element: HTMLElement, stop: Element, view: Window): HTMLElement[] {
  const found: HTMLElement[] = [];
  for (let node: Element | null = element; node && node !== stop; node = node.parentElement)
    for (let next = node.nextElementSibling; next; next = next.nextElementSibling) {
      if (!isHTMLElement(next) || next.classList.contains(GHOST) || next.hasAttribute(TEXT_SWAP_FADE)) continue;
      const position = view.getComputedStyle(next).position;
      if (position !== "absolute" && position !== "fixed") found.push(next);
    }
  return found;
}

function copyOf(element: HTMLElement): HTMLElement {
  const copy = element.cloneNode(true) as HTMLElement;
  copy.removeAttribute("id");
  copy.classList.add(GHOST);
  copy.setAttribute("aria-hidden", "true");
  copy.setAttribute("data-find-skip", "");
  copy.setAttribute("inert", "");
  return copy;
}

function stopPlaying(state: SwapState) {
  for (const animation of state.playing) animation.cancel();
  state.playing = [];
}

function dropGhosts(state: SwapState, keep = 0) {
  while (state.ghosts.length > keep) {
    const ghost = state.ghosts.shift()!;
    ghost.leaving?.cancel();
    ghost.element.remove();
  }
}

function clear(state: SwapState) {
  stopPlaying(state);
  dropGhosts(state);
  state.observer?.disconnect();
  state.observer = null;
}

/// Attach the returned ref to the element holding the words; `text` is what they say.
export function useTextSwap<T extends HTMLElement>(text: string | undefined): RefObject<T | null> {
  const ref = useRef<T>(null);
  const state = useRef<SwapState>({
    element: null,
    text: undefined,
    width: -1,
    left: -1,
    copy: null,
    ghosts: [],
    playing: [],
    observer: null,
  });

  // Runs on every commit (the clock beside the words ticks each second) and returns at once unless
  // the words or their element changed.
  useLayoutEffect(() => {
    const swap = state.current;
    const element = ref.current;
    if (element !== swap.element) {
      clear(swap);
      Object.assign(swap, { element, text, width: -1, left: -1, copy: element ? copyOf(element) : null });
      if (!element) return;
      swap.left = element.offsetLeft;
      const view = element.ownerDocument.defaultView;
      if (view && "ResizeObserver" in view) {
        swap.observer = new view.ResizeObserver((entries) => {
          const entry = entries.at(-1);
          if (entry) swap.width = entry.borderBoxSize?.[0]?.inlineSize ?? entry.contentRect.width;
        });
        swap.observer.observe(element);
      }
      return;
    }
    if (!element || text === swap.text) return;
    swap.text = text;
    const old = swap.copy;
    const oldWidth = swap.width;
    swap.copy = copyOf(element);
    const doc = element.ownerDocument;
    const view = doc.defaultView;
    const mode = motionMode(doc);
    // An engine with no Web Animations (a test DOM) changes the words the way motion off does.
    if (!view || !old || mode === "none" || typeof element.animate !== "function") {
      // An earlier change's old words go too: their fade is not in `playing`.
      stopPlaying(swap);
      dropGhosts(swap);
      swap.left = element.offsetLeft;
      return;
    }
    const stop = element.closest(`[${TEXT_SWAP_ROOT}]`) ?? element.parentElement ?? element;
    const followers = mode === "full" ? followersOf(element, stop, view) : [];
    const fading = [...stop.querySelectorAll<HTMLElement>(`[${TEXT_SWAP_FADE}]`)];
    // Where the line stands now, mid-change or at rest: the incoming words' fade and rise and the
    // followers' offset, read before their animations are cancelled.
    const now = view.getComputedStyle(element);
    const fromOpacity = Number.parseFloat(now.opacity);
    const from = {
      opacity: Number.isFinite(fromOpacity) ? fromOpacity : 1,
      y: mode === "full" ? translate(now.transform, "y") : 0,
    };
    const fromX = followers[0] ? translate(view.getComputedStyle(followers[0]).transform, "x") : 0;
    stopPlaying(swap);

    const width = element.getBoundingClientRect().width;
    const left = element.offsetLeft;
    const oldLeft = swap.left >= 0 ? swap.left : left;
    swap.left = left;
    // The clock moves by where the words end, so a mark that comes or goes before them moves it too.
    const shift = mode === "full" && oldWidth >= 0 ? oldLeft + oldWidth - (left + width) + fromX : 0;

    dropGhosts(swap, TEXT_SWAP_MAX_GHOSTS - 1);
    const ghost = old;
    Object.assign(ghost.style, {
      position: "absolute",
      // The old words leave from where they stood.
      left: `${oldLeft}px`,
      top: `${element.offsetTop}px`,
      ...(oldWidth >= 0 && { width: `${oldWidth}px` }),
    });
    element.parentElement?.insertBefore(ghost, element.nextSibling);
    const entry: SwapState["ghosts"][number] = { element: ghost };
    swap.ghosts.push(entry);
    // Faded out halfway: the old words are gone before the clock, sliding left, crosses them.
    const out =
      mode === "full"
        ? [
            { opacity: from.opacity, transform: `translateY(${from.y}px)` },
            { opacity: 0, offset: TEXT_SWAP_GONE_AT },
            { opacity: 0, transform: `translateY(${-TEXT_SWAP_RISE_PX}px)` },
          ]
        : [{ opacity: from.opacity }, { opacity: 0 }];
    const leaving = ghost.animate(out, {
      duration: MOTION_MS.micro,
      easing: MOTION_EASE_OUT,
      fill: "forwards",
    });
    entry.leaving = leaving;
    const gone = () => {
      ghost.remove();
      swap.ghosts = swap.ghosts.filter((other) => other !== entry);
    };
    leaving.onfinish = gone;
    leaving.oncancel = gone;

    const timing = {
      duration: mode === "full" ? MOTION_MS.standard : MOTION_MS.micro,
      easing: MOTION_EASE_OUT,
    };
    // The new words show only once the clock is out of their way: past TEXT_SWAP_SHOW_FROM when
    // they are shorter, and when they are longer (the clock slides right across them) not before it
    // lands.
    const showFrom = shift < 0 ? Math.max(TEXT_SWAP_SHOW_FROM, MOTION_MS.micro / timing.duration) : TEXT_SWAP_SHOW_FROM;
    const incoming =
      mode === "full"
        ? [
            { opacity: 0, transform: `translateY(${TEXT_SWAP_RISE_PX}px)` },
            { opacity: 0, offset: showFrom },
            { opacity: 1, transform: "translateY(0px)" },
          ]
        : [{ opacity: 0 }, { opacity: 1 }];
    swap.playing.push(element.animate(incoming, timing));
    for (const layer of fading) swap.playing.push(layer.animate([{ opacity: 0 }, { opacity: 1 }], timing));
    if (Math.abs(shift) >= 0.5)
      for (const follower of followers)
        swap.playing.push(
          follower.animate([{ transform: `translateX(${shift}px)` }, { transform: "translateX(0px)" }], {
            duration: MOTION_MS.micro,
            easing: MOTION_EASE_OUT,
          }),
        );
    for (const animation of swap.playing)
      animation.onfinish = () => {
        swap.playing = swap.playing.filter((other) => other !== animation);
      };
  });

  useLayoutEffect(() => {
    const swap = state.current;
    return () => {
      clear(swap);
      swap.element = null;
    };
  }, []);

  return ref;
}
