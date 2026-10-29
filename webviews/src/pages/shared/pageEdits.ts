// Automatic keep reasons for every page. Chrome learns from Blink, for every page and
// with no page code, that a document had form interaction or user edits
// (DocumentResourceCoordinator::SetHadFormInteraction and SetHadUserEdits); discard_eligibility_policy.cc
// then refuses to discard the page. A cmux page learns the same in its own document: one capture-phase
// `input` and `change` listener pair. Only trusted events count (the person typed, picked or toggled),
// and the host hears each reason once when it starts (PageKeepAlive), never per keystroke.
//
// The edits end when the page says they are saved (`EDITS_SAVED_EVENT`, or `PageKeepAlive.editsSaved`
// from a store), when it shows another route (`hashchange`), or with the document (the host ends a
// document's reasons on reload, crash or navigation: PageKeepReasons.documentEnded).
//
// `before_unload` is the page's own choice (`askBeforeUnload`), not a count of the window's listeners
// as Chrome's SuddenTerminationDisablerChanged is: TanStack's history adds a beforeunload listener when
// the router boots and asks only while a blocker is set, so a count would keep every router page.
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

const watched = new WeakSet<object>();

/**
 * Watches `doc` for edits and `win` for route changes, and holds the matching keep reasons on `keep`.
 * Once per document: a second call does nothing. Returns the end of the watch.
 */
export function watchPageEdits(doc: EventTarget, win: EventTarget, keep: PageKeepAlive): () => void {
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
  return () => {
    doc.removeEventListener("input", onEdit, listening);
    doc.removeEventListener("change", onEdit, listening);
    doc.removeEventListener(EDITS_SAVED_EVENT, onSaved);
    win.removeEventListener("hashchange", onRoute);
    watched.delete(doc);
  };
}

/**
 * The page asks before it unloads until the returned release: `win`'s beforeunload asks, and
 * `before_unload` keeps the hidden page from its discard for exactly as long. For a page with work it
 * cannot save on its own; one with a store ends its edits with `PageKeepAlive.editsSaved` instead.
 */
export function askBeforeUnload(win: EventTarget, keep: PageKeepAlive): () => void {
  const holder = {};
  const ask = (event: Event) => {
    event.preventDefault();
    // WebKit before Safari 17 asks only when returnValue is set.
    (event as BeforeUnloadEvent).returnValue = "";
  };
  win.addEventListener("beforeunload", ask);
  keep.set("before_unload", true, holder);
  let asking = true;
  return () => {
    if (!asking) return;
    asking = false;
    win.removeEventListener("beforeunload", ask);
    keep.set("before_unload", false, holder);
  };
}
