// The app's toasts never cover the composer, and the composer never moves for them (Leo,
// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
// thing ... If it needs to move because, like, the panes shift, sure, but otherwise, no."). Native
// toasts rest bottom-center over the window, over this page's foot. The page tells the host where
// its bottom stack is (`pane.toastAvoidance {rects}`: the question card, notices, the tray, the
// queued prompts and the composer card, in viewport CSS pixels), and the host lifts every toast above
// it (AgentPaneView+ToastAvoidance.swift, `CmuxToastAvoiding`), as it does over Home's message box.
// Nothing about a toast reaches the page's layout: the stage and the stack keep their place.
//
// The box is measured once per frame in which the stack or the pane changed size (a resize observer
// on the stack's parts, the dock and the pane's main column; a child-list observer on the dock only,
// never on the transcript), and sent only when it changed.
import { postNative } from "./native";

/// The bottom stack's box in the page's viewport, CSS pixels.
export type StackBox = { left: number; top: number; right: number; bottom: number };

/// Parts of the dock a toast may lie over: a new chat's hero lists sit in the dock's flow but are
/// not the stack under the transcript.
const NOT_STACK = ".acpmux-home-area";

/// The union of the dock's drawn parts (the dock is `display: contents` outside the floating
/// layout, so its own box is empty there), or none when no part takes room.
export function bottomStackBox(dock: Element): StackBox | undefined {
  let box: StackBox | undefined;
  for (const part of dock.children) {
    if (part.matches(NOT_STACK)) continue;
    const rect = part.getBoundingClientRect();
    if (!(rect.width > 0 && rect.height > 0)) continue;
    box = box
      ? {
          left: Math.min(box.left, rect.left),
          top: Math.min(box.top, rect.top),
          right: Math.max(box.right, rect.right),
          bottom: Math.max(box.bottom, rect.bottom),
        }
      : { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
  }
  if (!box) return undefined;
  const round = (value: number) => Math.round(value);
  return { left: round(box.left), top: round(box.top), right: round(box.right), bottom: round(box.bottom) };
}

const same = (a: StackBox | undefined, b: StackBox | undefined) =>
  a === b || (!!a && !!b && a.left === b.left && a.top === b.top && a.right === b.right && a.bottom === b.bottom);

/// Keeps the host told where `dock`'s stack is; the stop sends none, so the host's toasts stop
/// avoiding a stack that left. `send` gets the box (none: nothing to avoid).
export function watchToastAvoidance(dock: HTMLElement, send: (box: StackBox | undefined) => void): () => void {
  const view = dock.ownerDocument.defaultView;
  if (!view || typeof view.ResizeObserver !== "function") return () => {};
  let sent: StackBox | undefined;
  let frame = 0;
  const measure = () => {
    frame = 0;
    const box = bottomStackBox(dock);
    if (same(box, sent)) return;
    sent = box;
    send(box);
  };
  const schedule = () => {
    if (!frame) frame = view.requestAnimationFrame(measure);
  };
  const sizes = new view.ResizeObserver(schedule);
  const observeParts = () => {
    sizes.disconnect();
    sizes.observe(dock);
    if (dock.parentElement) sizes.observe(dock.parentElement);
    for (const part of dock.children) sizes.observe(part);
  };
  const parts = new view.MutationObserver(() => {
    observeParts();
    schedule();
  });
  parts.observe(dock, { childList: true });
  observeParts();
  view.addEventListener("resize", schedule);
  schedule();
  return () => {
    parts.disconnect();
    sizes.disconnect();
    view.removeEventListener("resize", schedule);
    if (frame) view.cancelAnimationFrame(frame);
    frame = 0;
    if (sent) send(undefined);
  };
}

/// Reports `dock`'s stack to the host for as long as it is mounted. A host that does not know the
/// call (an older app) ends the reports.
export function reportToastAvoidance(dock: HTMLElement): () => void {
  let live = true;
  let stop: (() => void) | undefined;
  const end = () => {
    if (!live) return;
    live = false;
    stop?.();
  };
  stop = watchToastAvoidance(dock, (box) => {
    void postNative("pane.toastAvoidance", { rects: box ? [box] : [] }).catch(end);
  });
  return end;
}
