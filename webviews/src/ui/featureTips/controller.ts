// The feature tip scheduler of one page (leo-workspace design/feature-tips.md): it watches the
// person's input and the page's state, asks policy.ts whether a tip may show, and keeps the records.
//
// Timer and listeners (their stop conditions):
// - One idle timer, armed only after an event (load, a key, press or scroll, focus, the agent
//   stopping, the toggle turning on), for the time policy.ts still needs; it never repeats on its own.
//   It is not armed once this launch showed its tip, every tip is done, the toggle is off or the app
//   keeps no records, and `stop()` clears it.
// - Capture listeners for keydown, pointerdown, wheel and click, plus focus, visibilitychange and the
//   launch store's storage event. They stay while some tip is not done (a use still has to be
//   recorded after this launch's tip), and `stop()` or the last tip done removes them.
import {
  allDone,
  isDone,
  pickTip,
  shownRecord,
  waitMs,
  waitsForTime,
  type FeatureTipEntry,
  type TipMoment,
  type TipRecords,
} from "./policy";
import type { LaunchStore, TipHost } from "./store";

export interface TipAnchor {
  /** The control, found in the page by this selector. */
  selector: string;
  /** Which side of the control the tip opens on. */
  side: "top" | "bottom";
}

export interface ShownTip {
  tip: FeatureTipEntry;
  element: Element;
  side: "top" | "bottom";
}

export interface TipControllerOptions {
  tips: readonly FeatureTipEntry[];
  anchors: Readonly<Record<string, TipAnchor>>;
  host: TipHost;
  launch: LaunchStore;
  doc: Document;
  /** A draft in the composer, or a field being typed in. */
  typing(): boolean;
  /** Called after every change of what shows. */
  onChange(shown: ShownTip | null): void;
  now?: () => number;
  setTimer?: (run: () => void, ms: number) => unknown;
  clearTimer?: (timer: unknown) => void;
  /** A menu, popover or dialog is open (default: one is in the page). */
  overlayOpen?: (doc: Document) => boolean;
  /** The page is the one the person looks at (default: visible and focused). */
  focused?: (doc: Document) => boolean;
  page?: string;
  /** When the page opened (default: now); the gallery's still passes a time long past. */
  openedAt?: number;
}

const OVERLAY =
  '[role="menu"], [role="listbox"], [role="alertdialog"], [aria-modal="true"], .ui-popup:not([data-feature-tip])';

export function pageOverlayOpen(doc: Document): boolean {
  return doc.querySelector(OVERLAY) !== null;
}

export function pageFocused(doc: Document): boolean {
  return doc.visibilityState !== "hidden" && doc.hasFocus();
}

/** Whether the control is drawn where the person can see it. */
export function anchorShown(element: Element | null): element is Element {
  if (!element || !element.isConnected || element.closest("[hidden], [inert], [aria-hidden='true']")) return false;
  const box = element.getBoundingClientRect();
  const view = element.ownerDocument.defaultView;
  if (box.width <= 0 || box.height <= 0) return false;
  if (view && (box.bottom <= 0 || box.right <= 0 || box.top >= view.innerHeight || box.left >= view.innerWidth))
    return false;
  return view?.getComputedStyle(element).visibility !== "hidden";
}

export interface TipController {
  /** Reads the app's records and starts listening. */
  start(): Promise<void>;
  /** The page's state changed (the toggle, the agent's turn). */
  update(next: { enabled: boolean; streaming: boolean }): void;
  /** The tip's X: closed for good. */
  close(): void;
  /** The tip's element, so input inside it never puts it away. */
  setPopup(element: HTMLElement | null): void;
  stop(): void;
  readonly shown: ShownTip | null;
}

export function createTipController(options: TipControllerOptions): TipController {
  const { tips, anchors, host, launch, doc, typing, onChange } = options;
  const now = options.now ?? (() => Date.now());
  const setTimer = options.setTimer ?? ((run, ms) => setTimeout(run, ms));
  const clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  const overlayOpen = options.overlayOpen ?? pageOverlayOpen;
  const focused = options.focused ?? pageFocused;
  const page = options.page ?? `page-${Math.random().toString(36).slice(2)}`;
  const born = options.openedAt ?? now();
  let lastInput = born;
  let records: TipRecords | null = null;
  let enabled = true;
  let streaming = false;
  let shown: ShownTip | null = null;
  let popup: HTMLElement | null = null;
  let timer: unknown;
  let listening = false;
  let stopped = false;
  let unsubscribe: (() => void) | undefined;

  const element = (anchor: string) => {
    const spec = anchors[anchor];
    return spec ? doc.querySelector(spec.selector) : null;
  };

  const moment = (): TipMoment => ({
    enabled,
    hostReady: records !== null,
    streaming,
    typing: typing(),
    pageAgeMs: now() - born,
    idleMs: now() - lastInput,
    overlayOpen: overlayOpen(doc),
    focused: focused(doc),
    launch: launch.get(),
  });

  const disarm = () => {
    if (timer !== undefined) clearTimer(timer);
    timer = undefined;
  };

  const keep = (id: string, record: Parameters<TipHost["write"]>[1]) => {
    records = { ...records, [id]: record };
    void host.write(id, record).catch(() => undefined);
    if (records && allDone(tips, records)) unlisten();
  };

  const putAway = () => {
    if (!shown) return;
    shown = null;
    launch.release(page);
    onChange(null);
  };

  const arm = () => {
    disarm();
    if (stopped || shown || !records || !enabled || launch.get() || allDone(tips, records)) return;
    const current = moment();
    const pick = pickTip(current, tips, records, (anchor) => anchorShown(element(anchor)));
    if ("tip" in pick) return show(pick.tip);
    if (waitsForTime(pick.block)) timer = setTimer(arm, waitMs(current));
  };

  const show = (tip: FeatureTipEntry) => {
    const target = element(tip.anchor);
    if (!target || !launch.claim(tip.id, page)) return;
    keep(tip.id, shownRecord(records?.[tip.id]));
    shown = { tip, element: target, side: anchors[tip.anchor]?.side ?? "bottom" };
    onChange(shown);
  };

  // Realm-safe: the page's own Node and Element (a test page is another window).
  const asNode = (target: EventTarget | null): Node | null =>
    target !== null && typeof (target as Node).nodeType === "number" ? (target as Node) : null;
  const asElement = (target: EventTarget | null): Element | null =>
    asNode(target)?.nodeType === 1 ? (target as Element) : (asNode(target)?.parentElement ?? null);
  const inside = (target: EventTarget | null) => popup !== null && popup.contains(asNode(target));

  const onInput = (event: Event) => {
    if (inside(event.target)) return;
    lastInput = now();
    // The person went back to work: the tip goes away for this launch (a press on its control is a use, below).
    if (shown && !(event.type === "pointerdown" && shown.element.contains(asNode(event.target)))) putAway();
    arm();
  };

  const onClick = (event: Event) => {
    const target = asElement(event.target);
    if (!target || !records) return;
    for (const tip of tips) {
      const spec = anchors[tip.anchor];
      if (!spec || isDone(records[tip.id]) || !target.closest(spec.selector)) continue;
      keep(tip.id, "used");
      if (shown?.tip.id === tip.id) putAway();
    }
  };

  const onWake = () => arm();

  function listen() {
    if (listening) return;
    listening = true;
    for (const type of ["keydown", "pointerdown", "wheel"])
      doc.addEventListener(type, onInput, { capture: true, passive: true });
    doc.addEventListener("click", onClick, { capture: true });
    doc.addEventListener("visibilitychange", onWake);
    doc.defaultView?.addEventListener("focus", onWake);
    unsubscribe = launch.subscribe(onWake);
  }

  function unlisten() {
    if (!listening) return;
    listening = false;
    for (const type of ["keydown", "pointerdown", "wheel"]) doc.removeEventListener(type, onInput, { capture: true });
    doc.removeEventListener("click", onClick, { capture: true });
    doc.removeEventListener("visibilitychange", onWake);
    doc.defaultView?.removeEventListener("focus", onWake);
    unsubscribe?.();
    unsubscribe = undefined;
    disarm();
  }

  return {
    async start() {
      try {
        const read = await host.read();
        records = { ...read };
      } catch {
        // No records in this app: no tip, since a closed one could not stay closed.
        return;
      }
      if (stopped || allDone(tips, records)) return;
      listen();
      arm();
    },
    update(next) {
      const woke = (next.enabled && !enabled) || (!next.streaming && streaming);
      enabled = next.enabled;
      streaming = next.streaming;
      if (shown && (!enabled || streaming)) putAway();
      if (woke) arm();
      else if (!enabled) disarm();
    },
    close() {
      if (!shown) return;
      keep(shown.tip.id, "closed");
      putAway();
    },
    setPopup(element) {
      popup = element;
    },
    stop() {
      stopped = true;
      unlisten();
      putAway();
    },
    get shown() {
      return shown;
    },
  };
}
