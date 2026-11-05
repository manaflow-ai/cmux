// Session Info never flickers while the chat scrolls under it (Leo, 2026-11-03: "we NEED to have
// "dynamic" content such as the bottom running area + the session info thing not flicker EVER when
// im scrolling"). Where the panel lies over the transcript (over the chat's column, or pushed with
// part of its width over the chat's gutter), the rows and the scrollbar scrolled under it, blurred
// through its glass or seen through its unfilled body, changed its pixels on every scroll frame:
// 13 of 24 wheel steps painted a new image of it in Chromium and WebKit
// (test/running-chrome-scroll-steady.test.ts). The transcript now leaves the panel's box out, as it
// already leaves out the rows under the composer's stack (conversation.css `data-docked`): the
// panel's rectangle is cut from the scroller's clip, so what lies behind its glass is the pane, which
// does not move. The panel itself is unchanged.
//
// One ResizeObserver on the panel and the transcript's scroller (the panel's foot follows the
// composer; the chat narrows as a pushed panel slides in), set up while the panel shows and
// disconnected when it goes, plus a re-measure where its enter slide ends. It writes one shell
// property only when the cut changes.
import { useLayoutEffect, type RefObject } from "react";

/// The shell property the transcript's scroller clips by (conversation.css `.acpmux-scroll`).
export const CHAT_CUT = "--acpmux-session-info-cut";

/// The transcript's scroller in the shell: the chat's own, not one in a side panel.
const SCROLLER = ".acpmux-main .acpmux-scroll";

type Box = { left: number; top: number; right: number; bottom: number };

/// The clip that leaves `panel` out of `scroller` (both viewport boxes), as a `clip-path` polygon in
/// the scroller's own px, or undefined when they do not overlap. The outer box and the hole are one
/// even-odd path, so the hole cuts and the rest shows.
export function chatCut(scroller: Box, panel: Box): string | undefined {
  const left = Math.max(panel.left, scroller.left) - scroller.left;
  const right = Math.min(panel.right, scroller.right) - scroller.left;
  const top = Math.max(panel.top, scroller.top) - scroller.top;
  const bottom = Math.min(panel.bottom, scroller.bottom) - scroller.top;
  if (right - left < 1 || bottom - top < 1) return undefined;
  const px = (n: number) => `${Math.round(n * 2) / 2}px`;
  const [l, r, t, b] = [left, right, top, bottom].map(px);
  return `polygon(evenodd, 0 0, 100% 0, 100% 100%, 0 100%, 0 0, ${l} ${t}, ${l} ${b}, ${r} ${b}, ${r} ${t}, ${l} ${t})`;
}

/// Cuts `frame`'s box out of the chat's transcript while `on`.
export function useChatCut(frame: RefObject<HTMLElement | null>, on: boolean, layout: unknown): void {
  useLayoutEffect(() => {
    const panel = frame.current;
    const shell = panel?.closest<HTMLElement>(".acpmux-shell");
    if (!on || !panel || !shell) return;
    let written: string | undefined;
    const write = (value: string | undefined) => {
      if (value === written) return;
      written = value;
      if (value) shell.style.setProperty(CHAT_CUT, value);
      else shell.style.removeProperty(CHAT_CUT);
    };
    const measure = () => {
      const scroller = shell.querySelector<HTMLElement>(SCROLLER);
      write(scroller ? chatCut(scroller.getBoundingClientRect(), panel.getBoundingClientRect()) : undefined);
    };
    measure();
    // The panel opens sliding in (ui/presence.ts), which moves it without resizing it: the cut is
    // measured again where the slide ends, or it stays at the enter offset.
    panel.addEventListener("transitionend", measure);
    if (typeof ResizeObserver !== "function")
      return () => {
        panel.removeEventListener("transitionend", measure);
        write(undefined);
      };
    const observer = new ResizeObserver(measure);
    observer.observe(panel);
    const scroller = shell.querySelector<HTMLElement>(SCROLLER);
    if (scroller) observer.observe(scroller);
    return () => {
      panel.removeEventListener("transitionend", measure);
      observer.disconnect();
      write(undefined);
    };
  }, [frame, on, layout]);
}
