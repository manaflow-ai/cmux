// The page's open popovers, menus and hover cards, for the App's Session Info panel to step behind
// (Leo, 2026-11-02: "layering issue the context should go over top of the session info"). The panel
// is a native view above the page (AgentPaneView+SessionInfo.swift), so a popup the page draws where
// the panel floats (the context ring's card, the model and + menus) went under it. While the panel
// shows, the page sends the rects of its open popups (`pane.sessionInfo.overlays {rects}`) and the
// App cuts them out of the panel: it draws nothing there and takes no clicks, so the popup shows
// whole and answers hover and clicks.
//
// Every shared popup surface carries `.ui-popup` (Menu, Popover, ContextMenu, Combobox, the composer
// pickers) or `.ui-tooltip` (Tooltip, AnchoredCard: the context card); a custom one opts in with
// `data-native-overlay`. They are found as they mount (a mutation observer that reads only the added
// nodes, so a streaming transcript costs nothing more than the nodes it adds) and measured each frame
// while any is mounted, as they place and animate. The frame loop stops when the last one unmounts.
import { useEffect } from "react";
import { onVisualViewport, visualViewportScale } from "../../../../ui/visualViewportBox";
import { postNative } from "../../native";

export const OVERLAY_SELECTOR = ".ui-popup, .ui-tooltip, [data-native-overlay]";

/// A popup's box in the page's viewport, CSS pixels (where it shows under a pinch zoom), with its corner radius.
export type OverlayRect = { left: number; top: number; right: number; bottom: number; radius: number };

/// The most rects one report carries (the App refuses more).
export const OVERLAY_RECTS_MAX = 16;

/// The box of a shown popup, or none: unmounted, hidden, drawn by the App past the window's edge
/// (`data-escaped`, ui/popupHost.ts), or empty.
export function overlayRect(element: Element): OverlayRect | undefined {
  if (!element.isConnected || element.closest("[hidden],[data-escaped]")) return undefined;
  const view = element.ownerDocument.defaultView;
  const style = view?.getComputedStyle(element);
  if (style && (style.visibility === "hidden" || style.display === "none")) return undefined;
  const layout = element.getBoundingClientRect();
  if (!(layout.width > 0 && layout.height > 0)) return undefined;
  // Where it shows under a trackpad pinch, so the panel's cut-out zooms and pans with the popup.
  const box = onVisualViewport(layout, view);
  const radius = (Number.parseFloat(style?.borderTopLeftRadius ?? "") || 0) * visualViewportScale(view);
  const round = (value: number) => Math.round(value * 100) / 100;
  return {
    left: round(box.left),
    top: round(box.top),
    right: round(box.right),
    bottom: round(box.bottom),
    radius: round(Math.min(radius, (box.right - box.left) / 2, (box.bottom - box.top) / 2)),
  };
}

/**
 * Sends `post(rects)` whenever the set of shown popups or their boxes change, starting with the ones
 * already open; an empty list once none shows. Returns the stop, which sends an empty list if the
 * last report was not.
 */
export function reportOverlays(doc: Document, post: (rects: OverlayRect[]) => void): () => void {
  const view = doc.defaultView;
  if (!view) return () => undefined;
  const mounted = new Set<Element>();
  let frame = 0;
  let sent = "[]";
  const send = (rects: OverlayRect[]) => {
    const text = JSON.stringify(rects);
    if (text === sent) return;
    sent = text;
    post(rects);
  };
  const measure = () => {
    frame = 0;
    const rects: OverlayRect[] = [];
    for (const element of mounted) {
      if (!element.isConnected) {
        mounted.delete(element);
        continue;
      }
      const rect = overlayRect(element);
      if (rect && rects.length < OVERLAY_RECTS_MAX) rects.push(rect);
    }
    send(rects);
    // Placed and animated by their own code: read again next frame while any is mounted.
    if (mounted.size > 0) frame = view.requestAnimationFrame(measure);
  };
  const schedule = () => {
    if (!frame) frame = view.requestAnimationFrame(measure);
  };
  const collect = (node: Node) => {
    if (node.nodeType !== 1) return;
    const element = node as Element;
    if (element.matches(OVERLAY_SELECTOR)) mounted.add(element);
    // A portal mounts its positioner with the popup inside.
    if (element.firstElementChild) for (const inner of element.querySelectorAll(OVERLAY_SELECTOR)) mounted.add(inner);
  };
  const observer = new view.MutationObserver((records) => {
    const before = mounted.size;
    let removed = false;
    for (const record of records) {
      for (const node of record.addedNodes) collect(node);
      if (record.removedNodes.length > 0 && mounted.size > 0) removed = true;
    }
    if (mounted.size !== before || removed) schedule();
  });
  observer.observe(doc.body ?? doc.documentElement, { childList: true, subtree: true });
  for (const element of doc.querySelectorAll(OVERLAY_SELECTOR)) mounted.add(element);
  if (mounted.size > 0) schedule();
  return () => {
    observer.disconnect();
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    mounted.clear();
    send([]);
  };
}

/// While the App's Session Info panel shows, keeps it told where the page's popups are. An App that
/// does not know the call ends the reports.
export function useNativeOverlayReport(shown: boolean): void {
  useEffect(() => {
    if (!shown || typeof document === "undefined") return;
    let live = true;
    let stop: (() => void) | undefined;
    const end = () => {
      if (!live) return;
      live = false;
      stop?.();
    };
    stop = reportOverlays(document, (rects) => {
      // The stop's last empty report still goes, so the App drops its cut-outs with the panel.
      void postNative("pane.sessionInfo.overlays", { rects }).catch(end);
    });
    return end;
  }, [shown]);
}
