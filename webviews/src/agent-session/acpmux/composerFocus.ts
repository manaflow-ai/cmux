import { useEffect, useRef } from "react";
import type { PageClient } from "../../pages/shared/pageClient";
import { FOCUS_CONTENT_COMMAND, nothingFocused } from "../../pages/shared/pageFocus";
import { subscribePageStreams } from "../../pages/shared/pageStreams";

// The composer takes the keyboard inside the agent pane: it is focused when the pane opens
// or becomes active (not by a click) with nothing else focused in it, and a printed key typed while focus sits
// elsewhere in the pane (a session row, the transcript) goes into it. Only this page's own
// focus moves: the page cannot take focus from another pane or app, and a key reaches the
// page only when its pane already has the keyboard.

/// Sent on window by MarkdownField when its editor exists, so a composer that appears after
/// the page opened (a new chat, the handshake) still takes an idle focus.
export const COMPOSER_READY_EVENT = "acpmux-composer-ready";

/// A pointer press is the reader placing the keyboard themselves (Leo 2026-10-20, as in Claude
/// desktop: a click on the transcript, the background or another control blurs the composer). The
/// pane's activation that a click raises (the window's `focus`, the host's `focusContent` from
/// `becomeFirstResponder`) reaches the page just before or just after the press, so an activation
/// claim waits `ACTIVATION_SETTLE_MS` and is dropped when a press lands within `PRESS_WINDOW_MS`.
export const ACTIVATION_SETTLE_MS = 120;
export const PRESS_WINDOW_MS = 400;

/**
 * A pointer press outside the composer should release its editor focus. Most transcript rows are
 * not focusable, so relying on the browser's default focus transfer leaves the caret active after
 * a click on the chat. Keep this predicate separate so the capture-phase handler and its boundary
 * behavior stay testable without mounting the whole pane.
 */
export function shouldBlurComposerOnPress(target: Node | null, active: Element | null): boolean {
  if (!target || !active || !active.closest(".acpmux-composer-box")) return false;
  // Do not use `instanceof Element`: a pointer can come from an embedded document, and tests
  // create nodes in their own DOM realm. The DOM node type is stable across those boundaries.
  const targetElement = target.nodeType === 1 ? (target as Element) : target.parentElement;
  return targetElement?.closest(COMPOSER_CHROME) == null;
}

/// The composer's own rows: the box, the location strip above it, and the quiet row (mode, model,
/// context ring) and look radios under it. Those sit outside the box since Claude Code's split
/// (#22285), and a press on one of their chips must leave the prompt focused, so the chip's menu
/// hands the keyboard back to the prompt after a pick. A composer picker's menu drawn out of the box
/// (`overBackdrop`, the + menu) sits in `.acpmux-picker-layer`: a press on its rows is the composer's
/// too, or the blur closes the menu before the row takes the press.
const COMPOSER_CHROME =
  ".acpmux-composer-box, .acpmux-composer-strip, .acpmux-composer-foot, .acpmux-composer-under, .acpmux-picker-layer";

function blurActiveComposer(): void {
  const active = document.activeElement;
  if (active?.closest(".acpmux-composer-box")) (active as HTMLElement).blur();
}

export type KeyLike = {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  isComposing: boolean;
  defaultPrevented: boolean;
};

/// Controls that own their keys: text fields, and widgets that move or pick with keys.
const OWNS_KEYS =
  'input, textarea, select, [contenteditable=""], [contenteditable="true"], [role="textbox"], [role="menu"], [role="menubar"], [role="listbox"], [role="dialog"], [role="tree"], [role="grid"], [role="combobox"]';
const PRESSABLE =
  'button, a[href], [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], summary';

/// Whether a key typed with `target` focused should go into the composer.
export function routesToComposer(event: KeyLike, target: Element | null): boolean {
  if (event.defaultPrevented || event.isComposing) return false;
  if (event.metaKey || event.ctrlKey || event.altKey) return false;
  // One printed character: named keys (Enter, arrows, Escape, Tab) keep their meaning.
  if (event.key.length > 1 && /^[A-Za-z0-9]+$/.test(event.key)) return false;
  if (!target || target === target.ownerDocument?.body) return true;
  if (target.closest(OWNS_KEYS)) return false;
  if (event.key === " " && target.closest(PRESSABLE)) return false;
  return true;
}

/// What has the page's focus, for automation (chat_state): `composer` (the prompt), `none`, or
/// `tag#id.class` of the focused element.
export function focusedArea(element: Element | null): string {
  if (!element || element === element.ownerDocument?.body) return "none";
  // The prompt itself; a control in the composer's bar (a picker's search) reports as itself.
  if (element.closest(".acpmux-composer-box") && element.closest("[contenteditable='true'], .acpmux-md-field"))
    return "composer";
  const id = element.id ? `#${element.id}` : "";
  const className =
    typeof element.className === "string" && element.className ? `.${element.className.split(/\s+/)[0]}` : "";
  return `${element.tagName.toLowerCase()}${id}${className}`;
}

/// Whether the page's keyboard is free for the composer: nothing in it has focus, and no text
/// outside the composer is selected (a selection in the transcript, kept while the pane was away,
/// stays to be copied).
export function idleForComposer(doc: Document): boolean {
  if (!nothingFocused(doc)) return false;
  const selection = doc.getSelection();
  if (!selection || selection.isCollapsed) return true;
  const anchor = selection.anchorNode;
  const element = anchor instanceof Element ? anchor : (anchor?.parentElement ?? null);
  return element?.closest(".acpmux-composer-box") != null;
}

/// Installs the composer's claim on the keyboard. `focusComposer` focuses the prompt and
/// returns false when no composer is shown. `page` is the shared page host's client (null on the
/// old host): its `focusContent` command, sent each time the page's web view becomes first
/// responder, claims an idle keyboard too (pane-focus-DESIGN.md P18).
export function useComposerKeyboard(focusComposer: () => boolean, page: PageClient | null = null) {
  const latest = useRef(focusComposer);
  latest.current = focusComposer;
  useEffect(() => {
    const claimIfIdle = () => {
      if (idleForComposer(document)) latest.current();
    };
    let pressedAt = Number.NEGATIVE_INFINITY;
    let settling: ReturnType<typeof setTimeout> | undefined;
    const onPress = (event: PointerEvent) => {
      pressedAt = performance.now();
      clearTimeout(settling);
      settling = undefined;
      const target = event.target && "nodeType" in event.target ? (event.target as Node) : null;
      const active = document.activeElement;
      if (shouldBlurComposerOnPress(target, active)) {
        (active as HTMLElement).blur();
      }
    };
    // A live transcript preview is a nested browsing context: its pointer press does not bubble
    // to this document. The browser blurs the editor when that frame takes focus; keep the same
    // boundary explicit for hosts that only report the outer window blur.
    const onWindowBlur = () => blurActiveComposer();
    /// The pane became active (window focus, the host's focusContent): claim unless a click did it.
    const claimOnActivation = () => {
      if (performance.now() - pressedAt < PRESS_WINDOW_MS) return;
      clearTimeout(settling);
      settling = setTimeout(() => {
        settling = undefined;
        if (performance.now() - pressedAt >= PRESS_WINDOW_MS) claimIfIdle();
      }, ACTIVATION_SETTLE_MS);
    };
    const onKey = (event: KeyboardEvent) => {
      if (!routesToComposer(event, document.activeElement)) return;
      if (!latest.current()) return;
      event.preventDefault();
      // The field has the caret now; insertText goes through its input handling like typing.
      document.execCommand("insertText", false, event.key);
    };
    // The page opened (first paint) or its pane became active (the window and web view took focus).
    const first = requestAnimationFrame(claimIfIdle);
    window.addEventListener("focus", claimOnActivation);
    window.addEventListener("blur", onWindowBlur);
    window.addEventListener(COMPOSER_READY_EVENT, claimIfIdle);
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPress, true);
    let stopCommands: (() => void) | undefined;
    let ended = false;
    if (page)
      void subscribePageStreams(page, {
        onCommand: (command) => {
          if (command.command === FOCUS_CONTENT_COMMAND) claimOnActivation();
        },
      })
        .then((stop) => {
          if (ended) stop();
          else stopCommands = stop;
        })
        .catch(() => undefined);
    return () => {
      ended = true;
      stopCommands?.();
      cancelAnimationFrame(first);
      clearTimeout(settling);
      window.removeEventListener("focus", claimOnActivation);
      window.removeEventListener("blur", onWindowBlur);
      window.removeEventListener(COMPOSER_READY_EVENT, claimIfIdle);
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPress, true);
    };
  }, [page]);
}
