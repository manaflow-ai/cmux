// The page-side half of the cmux NEXT own-window picker (Inspect Element on the app's own web
// content). The native controller (CmuxNextApp UIInspectorController) owns the event monitor, the
// screenshot and the composer delivery; it drives this page through `globalThis.__cmuxUiPointer`:
// `start` and `stop` around a pick, `highlight` and `pick` at a point in CSS px, and
// `inspectMenuTarget` when the person chose Inspect Element in the page's right-click menu.
//
// Right-click > Inspect Element holds the element that was right-clicked (Leo, 2026-11-08: "instead
// of ... being at your original cursor's position where you started the right-click menu, it does
// it at where your mouse currently is"). The page records that element on `contextmenu`, before the
// native menu opens, so content that moves while the menu is open (a streaming reply) cannot swap
// it; the menu's own point is the fallback. The hold lasts through the grace rule in grace.ts.
//
// While picking (Leo, 2026-11-08: "im also not entirely sure what it's used for" and "you should be
// able to just see maybe some sort of preview as you're going and hovering"), a hint says what the
// picker is for and its keys, and a label beside the outline shows what a click would pick
// (overlay.ts, labelModel.ts). The page takes its keys in the capture phase, ahead of the composer:
// Esc cancels, the arrows walk the tree (walk.ts), Enter picks the outlined element. A walked
// element holds against the pointer by the same grace rule as Inspect Element's.
import { graceAfterMove, startGrace, type UiPointerGrace } from "./grace";
import {
  UI_POINTER_LABEL_DENSITY,
  UI_POINTER_LABEL_PLACEMENT,
  type LabelDensity,
  type LabelPlacement,
} from "./labelModel";
import { createOverlay, type UiPointerOverlay } from "./overlay";
import { reportOf, type UiPointerReport } from "./report";
import { walkFrom, type WalkDirection } from "./walk";

export type { UiPointerReport } from "./report";

export type UiPointerControl = {
  start(): void;
  stop(): void;
  highlight(x: number, y: number): void;
  pick(x: number, y: number): void;
  hide(): void;
  inspectMenuTarget(x: number, y: number): void;
  /** The element the outline is on now (tests and the debug read). */
  current(): Element | null;
};

type Options = {
  post: (report: UiPointerReport) => void;
  /** The person cancelled from the page (Esc reached it); the native picker stops too. */
  cancel?: () => void;
  /** The clock the grace rule reads; tests pass their own. */
  now?: () => number;
  /** The label's look; the gallery compares the others, the pane takes the defaults. */
  label?: { density?: LabelDensity; placement?: LabelPlacement };
};

/** How far the native menu's point may sit from the page's recorded right-click and still be it. */
const MENU_POINT_SLOP_PX = 12;
const WALK_KEYS: Record<string, WalkDirection> = {
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
};

/**
 * Installs the picker in `doc`: the right-click recorder now (it must see the `contextmenu` that
 * comes before Inspect Element), the overlay, pointer and key listeners only between `start` and `stop`.
 */
export function installUiPointer(doc: Document, options: Options): UiPointerControl {
  const now = options.now ?? (() => performance.now());
  const look = {
    density: options.label?.density ?? UI_POINTER_LABEL_DENSITY,
    placement: options.label?.placement ?? UI_POINTER_LABEL_PLACEMENT,
  };
  const view = doc.defaultView;
  let menuTarget: { element: Element; x: number; y: number } | null = null;
  let overlay: UiPointerOverlay | null = null;
  let current: Element | null = null;
  let grace: UiPointerGrace | null = null;
  let held: Element | null = null;
  let pointer: { x: number; y: number } | null = null;
  /** The children an Up walk came from, innermost last (walk.ts). */
  let trail: Element[] = [];

  doc.addEventListener(
    "contextmenu",
    (event) => {
      const target = event.target;
      menuTarget = target instanceof Element ? { element: target, x: event.clientX, y: event.clientY } : null;
    },
    true,
  );

  const ours = (element: Element | null) => !element || (overlay !== null && overlay.host.contains(element));

  const ensure = () => {
    if (overlay?.host.isConnected) return;
    overlay = createOverlay(doc, look);
  };

  const outlineOn = (element: Element | null) => {
    ensure();
    current = element;
    overlay?.show(element, pointer);
  };

  /** Holds `element` against the pointer until a deliberate move (grace.ts). */
  const hold = (element: Element | null) => {
    held = element;
    grace = element ? startGrace(now()) : null;
  };

  const elementAt = (x: number, y: number) => {
    const element = doc.elementFromPoint(x, y);
    return ours(element) ? null : element;
  };

  const onMove = (event: MouseEvent) => {
    pointer = { x: event.clientX, y: event.clientY };
    if (held && grace) {
      grace = graceAfterMove(grace, now(), event.clientX, event.clientY);
      if (grace) {
        overlay?.show(current, pointer);
        return;
      }
      held = null;
    }
    const element = elementAt(event.clientX, event.clientY);
    if (element !== current) trail = [];
    outlineOn(element);
  };

  const onKey = (event: KeyboardEvent) => {
    if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
    const direction = WALK_KEYS[event.key];
    if (event.key !== "Escape" && event.key !== "Enter" && !direction) return;
    // The picker's key: no composer caret move, no send, no other page handler.
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.key === "Escape") {
      control.stop();
      options.cancel?.();
    } else if (event.key === "Enter") {
      if (current?.isConnected) options.post(reportOf(current));
    } else if (current?.isConnected && direction) {
      const next = walkFrom(current, direction, trail, ours);
      if (!next) return;
      if (direction === "up") trail.push(current);
      else if (direction === "down") trail = trail.filter((element) => element !== next);
      else trail = [];
      hold(next);
      outlineOn(next);
    }
  };

  let listening = false;
  const control: UiPointerControl = {
    start() {
      ensure();
      if (listening) return;
      listening = true;
      doc.addEventListener("mousemove", onMove, true);
      (view ?? doc).addEventListener("keydown", onKey as EventListener, true);
    },
    stop() {
      if (listening) {
        doc.removeEventListener("mousemove", onMove, true);
        (view ?? doc).removeEventListener("keydown", onKey as EventListener, true);
      }
      listening = false;
      overlay?.remove();
      overlay = null;
      current = null;
      held = null;
      grace = null;
      pointer = null;
      trail = [];
    },
    highlight(x, y) {
      control.start();
      outlineOn(elementAt(Number(x), Number(y)));
    },
    pick(x, y) {
      control.start();
      const element = held?.isConnected ? held : elementAt(Number(x), Number(y));
      outlineOn(element);
      if (element) options.post(reportOf(element));
    },
    hide() {
      overlay?.hide();
    },
    inspectMenuTarget(x, y) {
      control.start();
      const recorded = menuTarget;
      const matches =
        recorded !== null &&
        recorded.element.isConnected &&
        Math.hypot(recorded.x - Number(x), recorded.y - Number(y)) <= MENU_POINT_SLOP_PX;
      const element = matches ? recorded.element : elementAt(Number(x), Number(y));
      hold(element);
      outlineOn(element);
    },
    current: () => current,
  };
  return control;
}
