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
import { graceAfterMove, startGrace, type UiPointerGrace } from "./grace";

/** What the page reports for a picked element: the native controller builds the reference from it. */
export type UiPointerReport = {
  selector: string;
  tag_name: string;
  text_content: string;
  dom_snippet: string;
  component: string | null;
  source_location: string | null;
  bounds: { x: number; y: number; width: number; height: number };
  viewport: { width: number; height: number };
  computed_styles: Record<string, string>;
};

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
  /** The clock the grace rule reads; tests pass their own. */
  now?: () => number;
};

/** How far the native menu's point may sit from the page's recorded right-click and still be it. */
const MENU_POINT_SLOP_PX = 12;
const STYLE_KEYS = [
  "display",
  "position",
  "width",
  "height",
  "margin",
  "padding",
  "font-family",
  "font-size",
  "font-weight",
  "line-height",
  "color",
  "background-color",
  "border-radius",
];

const bounded = (value: unknown, limit: number) => String(value || "").slice(0, limit);

function selectorOf(element: Element): string {
  if (element.id) return `#${CSS.escape(element.id)}`;
  const testid = element.getAttribute("data-testid");
  if (testid) return `${element.localName}[data-testid="${CSS.escape(testid)}"]`;
  const aria = element.getAttribute("aria-label");
  if (aria) return `${element.localName}[aria-label="${CSS.escape(aria)}"]`;
  return element.localName || "element";
}

function reportOf(element: Element): UiPointerReport {
  const view = element.ownerDocument.defaultView ?? window;
  const rect = element.getBoundingClientRect();
  const computed = view.getComputedStyle(element);
  const styles: Record<string, string> = {};
  for (const key of STYLE_KEYS) styles[key] = bounded(computed.getPropertyValue(key), 160);
  return {
    selector: selectorOf(element),
    tag_name: element.localName || "element",
    text_content: bounded((element as HTMLElement).innerText ?? element.textContent, 2000),
    dom_snippet: bounded(element.outerHTML, 2400),
    component: element.closest("[data-cmux-component]")?.getAttribute("data-cmux-component") || null,
    source_location: element.closest("[data-cmux-source]")?.getAttribute("data-cmux-source") || null,
    bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    viewport: { width: view.innerWidth, height: view.innerHeight },
    computed_styles: styles,
  };
}

/**
 * Installs the picker in `doc`: the right-click recorder now (it must see the `contextmenu` that
 * comes before Inspect Element), the outline and pointer listener only between `start` and `stop`.
 */
export function installUiPointer(doc: Document, options: Options): UiPointerControl {
  const now = options.now ?? (() => performance.now());
  let menuTarget: { element: Element; x: number; y: number } | null = null;
  let host: HTMLDivElement | null = null;
  let outline: HTMLDivElement | null = null;
  let current: Element | null = null;
  let grace: UiPointerGrace | null = null;
  let held: Element | null = null;

  doc.addEventListener(
    "contextmenu",
    (event) => {
      const target = event.target;
      menuTarget = target instanceof Element ? { element: target, x: event.clientX, y: event.clientY } : null;
    },
    true,
  );

  const ours = (element: Element | null) => !element || (host !== null && host.contains(element));

  const ensure = () => {
    if (host?.isConnected) return;
    host = doc.createElement("div");
    host.dataset.cmuxUiPointer = "";
    host.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:var(--layer-debug)";
    outline = doc.createElement("div");
    outline.dataset.cmuxUiPointerOutline = "";
    outline.style.cssText =
      "position:fixed;display:none;pointer-events:none;box-sizing:border-box;" +
      "border:2px solid var(--agent-accent);" +
      "background:color-mix(in srgb, var(--agent-accent) 12%, transparent);border-radius:3px";
    host.append(outline);
    doc.documentElement.append(host);
  };

  const outlineOn = (element: Element | null) => {
    ensure();
    current = element;
    if (!outline) return;
    if (!element) {
      outline.style.display = "none";
      return;
    }
    const rect = element.getBoundingClientRect();
    Object.assign(outline.style, {
      display: "block",
      left: `${rect.x}px`,
      top: `${rect.y}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
    });
  };

  const elementAt = (x: number, y: number) => {
    const element = doc.elementFromPoint(x, y);
    return ours(element) ? null : element;
  };

  const onMove = (event: MouseEvent) => {
    if (held && grace) {
      grace = graceAfterMove(grace, now(), event.clientX, event.clientY);
      if (grace) return;
      held = null;
    }
    outlineOn(elementAt(event.clientX, event.clientY));
  };

  let listening = false;
  const control: UiPointerControl = {
    start() {
      ensure();
      if (listening) return;
      listening = true;
      doc.addEventListener("mousemove", onMove, true);
    },
    stop() {
      if (listening) doc.removeEventListener("mousemove", onMove, true);
      listening = false;
      host?.remove();
      host = null;
      outline = null;
      current = null;
      held = null;
      grace = null;
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
      if (outline) outline.style.display = "none";
    },
    inspectMenuTarget(x, y) {
      control.start();
      const recorded = menuTarget;
      const matches =
        recorded !== null &&
        recorded.element.isConnected &&
        Math.hypot(recorded.x - Number(x), recorded.y - Number(y)) <= MENU_POINT_SLOP_PX;
      const element = matches ? recorded.element : elementAt(Number(x), Number(y));
      held = element;
      grace = element ? startGrace(now()) : null;
      outlineOn(element);
    },
    current: () => current,
  };
  return control;
}
