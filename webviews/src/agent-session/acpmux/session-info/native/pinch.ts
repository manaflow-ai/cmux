// The page's trackpad pinch, for the App's Session Info panel to zoom and pan with (Leo, 2026-11-12:
// "evidently you zoom in and it doesn't really, you know, it doesn't follow"). A pinch in a Chromium
// page zooms its visual viewport only: the content is scaled and panned on screen while the layout
// stays (ui/visualViewportBox.ts). The panel is a native view above the page, placed from the page's
// layout numbers (`top`, `side`, `width`), so it stayed at its place and size over the zoomed page.
// While the panel shows, the page sends the pinch (`pane.sessionInfo.pinch {scale, left, top}`, the
// visual viewport's scale and its offset into the layout, CSS pixels) and the App draws the panel
// where and as large as the page's content shows.
//
// Cost: two listeners on the visual viewport, nothing while it is still; a pinch sends at most one
// report a frame, and none when the numbers did not change.
import { useEffect } from "react";
import { visualViewportScale } from "../../../../ui/visualViewportBox";
import { postNative } from "../../native";

/// The visual viewport's scale and its offset into the layout viewport, CSS pixels.
export type Pinch = { scale: number; left: number; top: number };

/// No pinch: what the App assumes before the first report and after the last.
export const NO_PINCH: Pinch = { scale: 1, left: 0, top: 0 };

/// The page's pinch now.
export function readPinch(view: Window): Pinch {
  const visual = view.visualViewport;
  const round = (value: number) => Math.round(value * 1000) / 1000;
  const offset = (value: number | undefined) => (value !== undefined && Number.isFinite(value) ? round(value) : 0);
  return {
    scale: round(visualViewportScale(view)),
    left: offset(visual?.offsetLeft),
    top: offset(visual?.offsetTop),
  };
}

/**
 * Sends `post(pinch)` when the page's pinch changes, starting with the current one unless it is none.
 * Returns the stop, which sends no pinch if the last report was one.
 */
export function reportPinch(view: Window, post: (pinch: Pinch) => void): () => void {
  let sent = JSON.stringify(NO_PINCH);
  let frame = 0;
  const send = (pinch: Pinch) => {
    const text = JSON.stringify(pinch);
    if (text === sent) return;
    sent = text;
    post(pinch);
  };
  const measure = () => {
    frame = 0;
    send(readPinch(view));
  };
  const schedule = () => {
    if (!frame) frame = view.requestAnimationFrame(measure);
  };
  view.visualViewport?.addEventListener("resize", schedule);
  view.visualViewport?.addEventListener("scroll", schedule);
  measure();
  return () => {
    view.visualViewport?.removeEventListener("resize", schedule);
    view.visualViewport?.removeEventListener("scroll", schedule);
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    send(NO_PINCH);
  };
}

/// While the App's Session Info panel shows, keeps it told of the page's pinch. An App that does not
/// know the call ends the reports.
export function useNativePinchReport(shown: boolean): void {
  useEffect(() => {
    if (!shown || typeof window === "undefined") return;
    let live = true;
    let stop: (() => void) | undefined;
    const end = () => {
      if (!live) return;
      live = false;
      stop?.();
    };
    stop = reportPinch(window, (pinch) => {
      // The stop's last report still goes, so the App lays the panel out unzoomed again.
      void postNative("pane.sessionInfo.pinch", pinch).catch(end);
    });
    return end;
  }, [shown]);
}
