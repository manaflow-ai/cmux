// The feature tip scheduler of one page (leo-workspace design/feature-tips.md): it watches the
// person's input and the page's state, asks policy.ts whether a tip may show, and keeps the records.
//
// Timer and listeners (their stop conditions):
// - One idle timer, armed only after an event (load, a key, press or scroll, focus, the agent
//   stopping, the toggle turning on), for the time policy.ts still needs; it never repeats on its own.
//   It is not armed once this page asked the app for its tip, every tip is done, the toggle is off
//   or the app keeps no records, and `stop()` clears it.
// - Capture listeners for keydown, pointerdown, wheel and click, plus focus and visibilitychange.
//   They stay while some tip is not done or one shows (a use still has to be recorded after this
//   launch's tip), and `stop()` or the last tip done, once none shows, removes them.
import {
  allDone,
  isDone,
  pickTip,
  waitMs,
  waitsForTime,
  type FeatureTipEntry,
  type TipMoment,
  type TipRecord,
  type TipState,
} from "./policy";
import type { TipHost } from "./store";
import { openOverlay } from "../openOverlay";

export interface TipAnchor {
  /** The control, found in the page by this selector. */
  selector: string;
  /** The feature the control is: a tip about it never shows once it was used (the app knows). */
  feature?: string;
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
  /** When the page opened (default: now); the gallery's still passes a time long past. */
  openedAt?: number;
}

/** A menu, popover, dialog, picker, hover card or tooltip is open: never a tip over one. Checked
    each time the scheduler looks, when its timer fires and again when the app answers. */
export function pageOverlayOpen(doc: Document): boolean {
  return openOverlay(doc, "[data-feature-tip]");
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
  const { tips, anchors, host, doc, typing, onChange } = options;
  const now = options.now ?? (() => Date.now());
  const setTimer = options.setTimer ?? ((run, ms) => setTimeout(run, ms));
  const clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>));
  const overlayOpen = options.overlayOpen ?? pageOverlayOpen;
  const focused = options.focused ?? pageFocused;
  const born = options.openedAt ?? now();
  let lastInput = born;
  let state: TipState | null = null;
  let enabled = true;
  let streaming = false;
  let shown: ShownTip | null = null;
  let popup: HTMLElement | null = null;
  let timer: unknown;
  let listening = false;
  let stopped = false;
  /** This launch's tip went to some page (this one or another): this page shows none. */
  let spent = false;
  /** A claim is on its way to the app. */
  let claiming = false;

  const element = (anchor: string) => {
    const spec = anchors[anchor];
    return spec ? doc.querySelector(spec.selector) : null;
  };

  const moment = (): TipMoment => ({
    enabled,
    hostReady: state !== null,
    streaming,
    typing: typing(),
    pageAgeMs: now() - born,
    idleMs: now() - lastInput,
    overlayOpen: overlayOpen(doc),
    focused: focused(doc),
    spent: spent || claiming,
  });

  const disarm = () => {
    if (timer !== undefined) clearTimer(timer);
    timer = undefined;
  };

  const keep = (tip: FeatureTipEntry, record: TipRecord) => {
    if (!state) return;
    const used = new Set(state.used);
    if (record === "used" && tip.feature) used.add(tip.feature);
    state = { records: { ...state.records, [tip.id]: record }, used };
    void host.write(tip.id, record).catch(() => undefined);
    if (!shown && allDone(tips, state)) unlisten();
  };

  const putAway = () => {
    if (!shown) return;
    shown = null;
    onChange(null);
    if (state && allDone(tips, state)) unlisten();
  };

  const arm = () => {
    disarm();
    if (stopped || shown || spent || claiming || !state || !enabled || allDone(tips, state)) return;
    const current = moment();
    const pick = pickTip(current, tips, state, (anchor) => anchorShown(element(anchor)));
    if ("tip" in pick) return show(pick.tip);
    if (waitsForTime(pick.block)) timer = setTimer(arm, waitMs(current));
  };

  const show = (tip: FeatureTipEntry) => {
    claiming = true;
    void host
      .claim(tip.id, tip.feature)
      .catch(() => false)
      .then((granted) => {
        claiming = false;
        // One ask per page: a no (shown before, feature used, a tip too recently) stays a no.
        spent = true;
        if (!granted || !state) return;
        // The app recorded it shown. The moment may have passed while it answered: the rules win.
        state = { ...state, records: { ...state.records, [tip.id]: "shown" } };
        const target = element(tip.anchor);
        if (
          stopped ||
          !(
            "tip" in pickTip({ ...moment(), spent: false }, [tip], { ...state, records: {} }, () => anchorShown(target))
          )
        )
          return;
        shown = { tip, element: target!, side: anchors[tip.anchor]?.side ?? "bottom" };
        onChange(shown);
      });
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
    if (shown && !shown.element.isConnected) putAway();
    // The person went back to work: the tip goes away for this launch (a press on its control is a use, below).
    if (shown && !(event.type === "pointerdown" && shown.element.contains(asNode(event.target)))) putAway();
    arm();
  };

  const onClick = (event: Event) => {
    const target = asElement(event.target);
    if (!target || !state) return;
    for (const tip of tips) {
      const spec = anchors[tip.anchor];
      const open = shown?.tip.id === tip.id || !isDone(tip, state);
      if (!spec || !open || !target.closest(spec.selector)) continue;
      keep(tip, "used");
      if (shown?.tip.id === tip.id) putAway();
    }
  };

  const onWake = () => {
    if (shown && !shown.element.isConnected) putAway();
    arm();
  };

  function listen() {
    if (listening) return;
    listening = true;
    for (const type of ["keydown", "pointerdown", "wheel"])
      doc.addEventListener(type, onInput, { capture: true, passive: true });
    doc.addEventListener("click", onClick, { capture: true });
    doc.addEventListener("visibilitychange", onWake);
    doc.defaultView?.addEventListener("focus", onWake);
  }

  function unlisten() {
    if (!listening) return;
    listening = false;
    for (const type of ["keydown", "pointerdown", "wheel"]) doc.removeEventListener(type, onInput, { capture: true });
    doc.removeEventListener("click", onClick, { capture: true });
    doc.removeEventListener("visibilitychange", onWake);
    doc.defaultView?.removeEventListener("focus", onWake);
    disarm();
  }

  return {
    async start() {
      try {
        const read = await host.read();
        state = { records: { ...read.records }, used: new Set(read.used) };
      } catch {
        // No records in this app: no tip, since a closed one could not stay closed.
        return;
      }
      if (stopped || allDone(tips, state)) return;
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
      keep(shown.tip, "closed");
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
