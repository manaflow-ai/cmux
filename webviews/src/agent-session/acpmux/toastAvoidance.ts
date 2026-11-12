// The app's toasts never cover the composer, and the composer never moves for them (Leo,
// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
// thing ... If it needs to move because, like, the panes shift, sure, but otherwise, no."). Native
// toasts rest bottom-center over the window, over this page's foot. The page tells the host where
// its bottom stack is (`pane.toastAvoidance {rects}`: the question card, notices, the tray, the
// queued prompts and the composer card, in viewport CSS pixels), and the host lifts every toast above
// it (AgentPaneView+ToastAvoidance.swift, `CmuxToastAvoiding`), as it does over Home's message box.
// Nothing about a toast reaches the page's layout: the stage and the stack keep their place.
//
// Every layout with a composer at its foot reports it: the chat's bottom stack (App.tsx's dock), the
// New Tab screen's composer card in its stage layout (newtab/NewTabScreen.tsx) and the Quick Chat's
// panel's bottom stack (QuickSurface.tsx: its asks, composer and key hints, whenever it is mounted). The host keeps one box per page, so the reports
// stack: the newest mounted one is sent, and when it stops the one under it is sent again.
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
/// layout, so its own box is empty there), or none when no part takes room. Parts matching `skip`
/// are not the stack.
export function bottomStackBox(dock: Element, skip: string = NOT_STACK): StackBox | undefined {
  let box: StackBox | undefined;
  for (const part of dock.children) {
    if (part.matches(skip)) continue;
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

/// One element's own box (a composer card), or none while it takes no room.
export function elementBox(element: Element | null | undefined): StackBox | undefined {
  const rect = element?.getBoundingClientRect();
  if (!rect || !(rect.width > 0 && rect.height > 0)) return undefined;
  const round = (value: number) => Math.round(value);
  return { left: round(rect.left), top: round(rect.top), right: round(rect.right), bottom: round(rect.bottom) };
}

const same = (a: StackBox | undefined, b: StackBox | undefined) =>
  a === b || (!!a && !!b && a.left === b.left && a.top === b.top && a.right === b.right && a.bottom === b.bottom);

/// Keeps the host told where `dock`'s stack is (`box` measures it: by default the union of its
/// parts); the stop sends none, so the host's toasts stop avoiding a stack that left. `send` gets the
/// box (none: nothing to avoid).
export function watchToastAvoidance(
  dock: HTMLElement,
  send: (box: StackBox | undefined) => void,
  box: (dock: HTMLElement) => StackBox | undefined = bottomStackBox,
): () => void {
  const view = dock.ownerDocument.defaultView;
  if (!view || typeof view.ResizeObserver !== "function" || typeof view.requestAnimationFrame !== "function")
    return () => {};
  let sent: StackBox | undefined;
  let frame = 0;
  const measure = () => {
    frame = 0;
    const next = box(dock);
    if (same(next, sent)) return;
    sent = next;
    send(next);
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

/// The mounted reports, oldest first; the host hears the newest one's box.
type Report = { box: StackBox | undefined };
const reports: Report[] = [];
/// What the host last heard (null: nothing yet), and whether it knows the call at all.
let posted: StackBox | undefined | null = null;
let unsupported = false;

function post(): void {
  if (unsupported) return;
  const box = reports.at(-1)?.box;
  if (posted !== null && same(box, posted)) return;
  posted = box;
  void postNative("pane.toastAvoidance", { rects: box ? [box] : [] }).catch(() => {
    // A host that does not know the call (an older app) ends the reports.
    unsupported = true;
  });
}

/// Tells the host the newest report's box again, changed or not. Each handshake (`ready`, a retry's
/// too, which keeps this document) clears the host's box, so the page sends it again once the host
/// answers: a mounted composer whose bounds never move is still avoided.
export function resendToastAvoidance(): void {
  posted = null;
  post();
}

/// Reports `dock`'s stack (or what `box` measures of it) to the host for as long as it is mounted.
/// A report mounted later takes over; when it stops, the host hears the one under it again.
export function reportToastAvoidance(
  dock: HTMLElement,
  box: (dock: HTMLElement) => StackBox | undefined = bottomStackBox,
): () => void {
  const report: Report = { box: undefined };
  reports.push(report);
  let live = true;
  const stop = watchToastAvoidance(
    dock,
    (next) => {
      report.box = next;
      if (live) post();
    },
    box,
  );
  return () => {
    if (!live) return;
    live = false;
    reports.splice(reports.indexOf(report), 1);
    stop();
    post();
  };
}

/// Forgets every report and what the host heard (tests).
export function resetToastAvoidanceReports(): void {
  reports.length = 0;
  posted = null;
  unsupported = false;
}
