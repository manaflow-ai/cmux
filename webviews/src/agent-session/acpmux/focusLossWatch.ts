// The page's half of the focus log (Swift FocusLog, `tunable.diagnostics.focusLog`;
// plans/cmux-next/focus-loss-AUDIT.md): a text input of the page (the composer, a search field)
// that loses the keyboard with no key or click in the last half second is recorded as a
// `focus-lost` flicker event, so a focus loss in a real session names its cause:
//
// - `removed`: the focused input left the document (a remount of it or of a parent).
// - `script`: page code called `focus()` or `blur()` just before (`op`, `on`: what it touched).
// - `page`: the page itself lost the keyboard (the app moved it to another view or window).
// - `moved`: focus went to another element of the page with none of the above.
//
// No text goes out: element kinds and short words only. The watch is one capture listener on
// the document and a wrapper on `focus` and `blur` that stores the last call's target and time.

export type FocusLossRecord = (fields: Record<string, string | number | boolean>) => void;

/// A key or click this recent (ms) is the person's own cause of the change.
export const INPUT_GRACE_MS = 500;

type ScriptCall = { op: "focus" | "blur"; on: string; at: number };

/// An element as a short kind: `textarea`, `input:search`, `editable`, `button`, `body`.
export function describeElement(element: Element | null | undefined): string {
  if (!element) return "none";
  const tag = element.tagName.toLowerCase();
  if (tag === "input") return `input:${(element as HTMLInputElement).type || "text"}`.slice(0, 32);
  if ((element as HTMLElement).isContentEditable) return "editable";
  const role = element.getAttribute("role");
  return (role ? `${tag}[${role}]` : tag).slice(0, 32);
}

/// Whether typing there writes text (where a lost focus is a lost keystroke).
export function isTextInput(element: EventTarget | null): element is HTMLElement {
  if (!(element instanceof HTMLElement)) return false;
  if (element instanceof HTMLTextAreaElement) return true;
  if (element instanceof HTMLInputElement)
    return !["button", "checkbox", "radio", "submit", "reset", "range", "color", "file"].includes(element.type);
  return element.isContentEditable;
}

/// The cause of a loss, from what the page saw (exported for tests).
export function lossCause(input: {
  connected: boolean;
  pageHasFocus: boolean;
  script: ScriptCall | undefined;
  now: number;
}): "removed" | "script" | "page" | "moved" {
  if (!input.connected) return "removed";
  if (input.script && input.now - input.script.at <= 50) return "script";
  if (!input.pageHasFocus) return "page";
  return "moved";
}

/// Starts the watch on `win`; returns a stop function (tests).
export function watchFocusLoss(
  win: Window,
  record: FocusLossRecord,
  now: () => number = () => win.performance.now(),
): () => void {
  const doc = win.document;
  let lastInput = Number.NEGATIVE_INFINITY;
  let lastScript: ScriptCall | undefined;
  const noteInput = () => {
    lastInput = now();
  };
  const proto = (win as Window & typeof globalThis).HTMLElement.prototype;
  const originalFocus = proto.focus;
  const originalBlur = proto.blur;
  proto.focus = function (this: HTMLElement, options?: FocusOptions) {
    lastScript = { op: "focus", on: describeElement(this), at: now() };
    return originalFocus.call(this, options);
  };
  proto.blur = function (this: HTMLElement) {
    lastScript = { op: "blur", on: describeElement(this), at: now() };
    return originalBlur.call(this);
  };
  const onFocusOut = (event: FocusEvent) => {
    const target = event.target;
    if (!isTextInput(target)) return;
    const at = now();
    if (at - lastInput <= INPUT_GRACE_MS) return;
    const script = lastScript;
    // Read where focus went once the change settled (after the removal or the next focus).
    queueMicrotask(() => {
      const cause = lossCause({ connected: target.isConnected, pageHasFocus: doc.hasFocus(), script, now: at });
      const fields: Record<string, string | number | boolean> = {
        cause,
        what: describeElement(target),
        to: describeElement(doc.activeElement),
        since: Math.min(Math.round(at - lastInput), 999_999),
      };
      if (cause === "script" && script) {
        fields.op = script.op;
        fields.on = script.on;
      }
      record(fields);
    });
  };
  for (const type of ["pointerdown", "keydown"]) win.addEventListener(type, noteInput, true);
  doc.addEventListener("focusout", onFocusOut, true);
  return () => {
    for (const type of ["pointerdown", "keydown"]) win.removeEventListener(type, noteInput, true);
    doc.removeEventListener("focusout", onFocusOut, true);
    proto.focus = originalFocus;
    proto.blur = originalBlur;
  };
}
