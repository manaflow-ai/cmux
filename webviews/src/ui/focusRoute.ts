// The one way page code moves the keyboard (plans/cmux-next/focus-loss-AUDIT.md, "Focus route"),
// the web half of Swift's FocusRoute. Each move names who started it and why, so the focus log's
// page half (agent-session/acpmux/focusLossWatch.ts) says which code took the keys, and a move the
// person did not start (`system`) is refused while they type into another text input.
//
//   focusRoute(composer, "system", "a new message's composer");
//   focusRoute(row, "person", "arrow key in the queue");
//
// A direct `.focus()` / `.blur()` still works; scripts/cmux-next/check-focus-routes.py refuses a
// new one at push.

/** Who started a move: a key, click or command of the person, or the page by itself. */
export type FocusOrigin = "person" | "system";

/** A move made through the route: who, why, and when (ms, `performance.now()`). */
export interface FocusRouteRecord {
  op: "focus" | "blur";
  origin: FocusOrigin;
  reason: string;
  at: number;
  refused: boolean;
}

/** A key this recent (ms) in another text input means the person is typing there. */
export const TYPING_GRACE_MS = 1000;

const recent: FocusRouteRecord[] = [];
const RECENT_LIMIT = 50;
let typedAt = Number.NEGATIVE_INFINITY;
let typedInto: Element | null = null;
let watching: Window | undefined;

function now(): number {
  return typeof performance === "undefined" ? Date.now() : performance.now();
}

function watch(win: Window | undefined): void {
  if (!win || watching === win) return;
  watching = win;
  win.addEventListener(
    "keydown",
    (event) => {
      // A shortcut (Command, Control) is a command, not typing.
      if (event.metaKey || event.ctrlKey) return;
      typedAt = now();
      typedInto = win.document.activeElement;
    },
    true,
  );
}

/** Whether `value` is a DOM element (of any window: no global constructor is read). */
function isElement(value: unknown): value is Element {
  return typeof value === "object" && value !== null && (value as Node).nodeType === 1;
}

/** Whether typing there writes text. */
export function isTypingTarget(element: Element | null | undefined): boolean {
  if (!isElement(element)) return false;
  const tag = element.tagName.toLowerCase();
  if (tag === "textarea") return true;
  if (tag === "input")
    return !["button", "checkbox", "radio", "submit", "reset", "range", "color", "file"].includes(
      (element as HTMLInputElement).type,
    );
  return (element as HTMLElement).isContentEditable === true;
}

/** Something that takes the keyboard: an element, or a handle with `focus` (an editor, a composer). */
export interface FocusTarget {
  focus(options?: FocusOptions): void;
}

/**
 * Whether a `system` move to `target` takes the keys from the text input the person typed into
 * within the last second (`typedInto`, `typedAt`). A move to that input itself, or to an element
 * inside it, takes nothing.
 */
export function refusesSystemMove(
  target: FocusTarget,
  active: Element | null,
  typedInto: Element | null,
  typedAt: number,
  at: number,
): boolean {
  if (!active || active !== typedInto || !isTypingTarget(active)) return false;
  if (isElement(target) && (target === active || target.contains(active))) return false;
  return at - typedAt <= TYPING_GRACE_MS;
}

function remember(record: FocusRouteRecord): void {
  recent.push(record);
  if (recent.length > RECENT_LIMIT) recent.shift();
}

/**
 * Focuses `element` through the route; false when it is refused (a `system` move while the person
 * types into another text input) or there is no element.
 */
export function focusRoute(
  element: FocusTarget | null | undefined,
  origin: FocusOrigin,
  reason: string,
  options?: FocusOptions,
): boolean {
  if (!element) return false;
  const doc = isElement(element) ? element.ownerDocument : typeof document === "undefined" ? undefined : document;
  watch(doc?.defaultView ?? undefined);
  const at = now();
  const refused = origin === "system" && refusesSystemMove(element, doc?.activeElement ?? null, typedInto, typedAt, at);
  remember({ op: "focus", origin, reason, at, refused });
  if (refused) return false;
  // focus-route: the route itself
  element.focus(options);
  return true;
}

/** Blurs `element` through the route (the person's or the page's own reason). */
export function blurRoute(element: HTMLElement | null | undefined, origin: FocusOrigin, reason: string): void {
  if (!element) return;
  watch(element.ownerDocument?.defaultView ?? undefined);
  remember({ op: "blur", origin, reason, at: now(), refused: false });
  // focus-route: the route itself
  element.blur();
}

/** The newest route record, if it is at most `withinMs` old (focusLossWatch names the cause). */
export function lastFocusRoute(withinMs: number, at: number = now()): FocusRouteRecord | undefined {
  const last = recent[recent.length - 1];
  return last && at - last.at <= withinMs ? last : undefined;
}

/** The route's recent moves, oldest first (the page's debug read). */
export function recentFocusRoutes(): readonly FocusRouteRecord[] {
  return recent;
}

/** Notes typing the route did not see (tests; a host-sent key): into `element`, at `at`. */
export function noteTypingForFocusRoute(element: Element | null, at: number = now()): void {
  typedInto = element;
  typedAt = at;
}
