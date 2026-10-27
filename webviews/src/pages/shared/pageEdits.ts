// Automatic keep reasons for every page (p13-webui-089). Chrome learns from Blink, for every page and
// with no page code, that a document had form interaction or user edits, and from the frame that it
// has a beforeunload handler (DocumentResourceCoordinator::SetHadFormInteraction and SetHadUserEdits,
// RenderFrameHostImpl::SuddenTerminationDisablerChanged); discard_eligibility_policy.cc then refuses
// to discard the page. A cmux page learns the same in its own document: one capture-phase `input`
// and `change` listener pair, and a watch of the window's beforeunload handlers. Only trusted events
// count (the person typed, picked or toggled), and the host hears each reason once when it starts
// (PageKeepAlive), never per keystroke.
//
// The edits end when the page says they are saved (`EDITS_SAVED_EVENT`, or `PageKeepAlive.editsSaved`
// from a store), when it shows another route (`hashchange`), or with the document (the host ends a
// document's reasons on reload, crash or navigation: PageKeepReasons.documentEnded).
import type { PageKeepAlive } from "./pageClient";

/**
 * The document event a page with no store of its own dispatches once its edits are saved, applied
 * or sent: it ends the page's `user_edits` and `form_interaction`.
 */
export const EDITS_SAVED_EVENT = "cmux.page.edits.saved";

/** Input types whose value is text the person wrote. `search` is a query, not an edit. */
const TEXT_INPUTS = new Set([
  "text",
  "email",
  "number",
  "password",
  "tel",
  "url",
  "date",
  "datetime-local",
  "month",
  "time",
  "week",
]);
/** Input types the person sets without writing: a form interaction. */
const CONTROL_INPUTS = new Set(["checkbox", "radio", "range", "color", "file"]);

/** The part of an element `editReason` reads. */
interface EditTarget {
  tagName?: unknown;
  type?: unknown;
  readOnly?: unknown;
  isContentEditable?: unknown;
}

/**
 * The keep reason an edit of `target` sets: `user_edits` for text written into a field or editable
 * content, `form_interaction` for a control set by hand (a checkbox, a select), null for anything else.
 */
export function editReason(target: unknown): "user_edits" | "form_interaction" | null {
  const element = target as EditTarget | null;
  if (!element || typeof element.tagName !== "string") return null;
  if (element.isContentEditable === true) return "user_edits";
  const readOnly = element.readOnly === true;
  switch (element.tagName.toUpperCase()) {
    case "TEXTAREA":
      return readOnly ? null : "user_edits";
    case "SELECT":
      return "form_interaction";
    case "INPUT": {
      const type = typeof element.type === "string" ? element.type.toLowerCase() : "text";
      if (TEXT_INPUTS.has(type)) return readOnly ? null : "user_edits";
      return CONTROL_INPUTS.has(type) ? "form_interaction" : null;
    }
    default:
      return null;
  }
}

/** The window whose beforeunload handlers the watch counts. */
export interface EditsWindow extends EventTarget {
  onbeforeunload?: unknown;
}

type ListenerOptions = boolean | AddEventListenerOptions | EventListenerOptions | undefined;

const watched = new WeakSet<object>();

/**
 * Watches `doc` for edits and `win` for beforeunload handlers, and holds the matching keep reasons
 * on `keep`. Once per document: a second call does nothing. Returns the end of the watch.
 */
export function watchPageEdits(doc: EventTarget, win: EditsWindow, keep: PageKeepAlive): () => void {
  if (watched.has(doc)) return () => {};
  watched.add(doc);
  const holder = {};
  const onEdit = (event: Event) => {
    if (!event.isTrusted) return;
    // A field inside a shadow root reaches the document retargeted to its host.
    const reason = editReason(event.composedPath?.()[0] ?? event.target);
    if (reason) keep.set(reason, true, holder);
  };
  const onSaved = () => keep.editsSaved();
  const onRoute = () => {
    keep.set("user_edits", false, holder);
    keep.set("form_interaction", false, holder);
  };
  const listening = { capture: true, passive: true };
  doc.addEventListener("input", onEdit, listening);
  doc.addEventListener("change", onEdit, listening);
  doc.addEventListener(EDITS_SAVED_EVENT, onSaved);
  win.addEventListener("hashchange", onRoute);
  const unwatch = watchBeforeUnload(win, (on) => keep.set("before_unload", on, holder));
  return () => {
    doc.removeEventListener("input", onEdit, listening);
    doc.removeEventListener("change", onEdit, listening);
    doc.removeEventListener(EDITS_SAVED_EVENT, onSaved);
    win.removeEventListener("hashchange", onRoute);
    unwatch();
    watched.delete(doc);
  };
}

/**
 * Reports whether `win` has a beforeunload handler: a listener added and not yet removed (one per
 * listener and capture flag, as the DOM counts them; an aborted signal removes it), or an
 * `onbeforeunload` function.
 */
function watchBeforeUnload(win: EditsWindow, report: (on: boolean) => void): () => void {
  const listeners = new Map<EventListenerOrEventListenerObject, Set<boolean>>();
  let property = false;
  // PageKeepAlive sends only a change, so a report that changes nothing costs nothing.
  const update = () => report(property || listeners.size > 0);
  const capture = (options: ListenerOptions) =>
    typeof options === "boolean" ? options : (options as EventListenerOptions | undefined)?.capture === true;
  const forget = (listener: EventListenerOrEventListenerObject, flag: boolean) => {
    const flags = listeners.get(listener);
    if (!flags?.delete(flag)) return;
    if (flags.size === 0) listeners.delete(listener);
    update();
  };

  const add = win.addEventListener;
  const remove = win.removeEventListener;
  win.addEventListener = function (
    this: EventTarget,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions,
  ) {
    add.call(this, type, listener, options);
    if (type !== "beforeunload" || !listener) return;
    const signal = typeof options === "object" ? (options as AddEventListenerOptions).signal : undefined;
    if (signal?.aborted) return;
    const flag = capture(options);
    const flags = listeners.get(listener) ?? new Set<boolean>();
    flags.add(flag);
    listeners.set(listener, flags);
    signal?.addEventListener("abort", () => forget(listener, flag), { once: true });
    update();
  };
  win.removeEventListener = function (
    this: EventTarget,
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: ListenerOptions,
  ) {
    remove.call(this, type, listener, options);
    if (type === "beforeunload" && listener) forget(listener, capture(options));
  };

  const restoreProperty = watchHandlerProperty(win, (on) => {
    property = on;
    update();
  });
  return () => {
    win.addEventListener = add;
    win.removeEventListener = remove;
    restoreProperty();
    listeners.clear();
    property = false;
    update();
  };
}

/** Wraps the window's own `onbeforeunload` accessor so a set reports whether it holds a function. */
function watchHandlerProperty(win: EditsWindow, report: (on: boolean) => void): () => void {
  let owner: object | null = win;
  let descriptor: PropertyDescriptor | undefined;
  while (owner && !descriptor) {
    descriptor = Object.getOwnPropertyDescriptor(owner, "onbeforeunload");
    if (!descriptor) owner = Object.getPrototypeOf(owner) as object | null;
  }
  const { get, set } = descriptor ?? {};
  if (!get || !set || (owner === win && descriptor?.configurable !== true)) return () => {};
  Object.defineProperty(win, "onbeforeunload", {
    configurable: true,
    enumerable: descriptor?.enumerable ?? true,
    get: () => get.call(win),
    set: (value: unknown) => {
      set.call(win, value);
      report(typeof value === "function");
    },
  });
  if (typeof get.call(win) === "function") report(true);
  return () => {
    if (owner === win && descriptor) Object.defineProperty(win, "onbeforeunload", descriptor);
    else delete (win as { onbeforeunload?: unknown }).onbeforeunload;
  };
}
