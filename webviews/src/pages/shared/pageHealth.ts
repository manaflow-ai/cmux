// App health, the page's half (design/app-health.md; the host's model is the Rust health model, part
// kind `page`). Every page that boots through the page bridge gets it from `createPageClient`, once
// per document, with no page code:
//
// - Heartbeat: while the page is visible it calls `cmux.page.heartbeat {handled}` every `HEARTBEAT_MS`,
//   and once at once when it becomes visible. A hidden page sends none (the host never times a hidden
//   part, so the cost stays the same however many pages are open). `handled` counts the key and
//   pointer presses the page's script received; the host counts the ones it sent, so a page that
//   takes input but never runs its handlers reads as stuck. A host without the op stops the beats.
// - Kept state: the scroll position of the scroller that moved last (scrollers.ts), and the draft in
//   a focused field that opted in (`[data-cmux-restore-draft]`: a textarea or plain contenteditable),
//   go to sessionStorage, keyed by the page's URL, with each beat (the autosave a hung page's reload
//   falls back on), when the page hides or unloads, and on the host's `cmux.page.save_state` before it
//   reloads the page. After a load they come back once. Drafts are opt-in because a field bound to a
//   document (the Markdown source) saves what it is given: putting an old draft back would write it
//   over a newer file. Editors that keep their own draft (the agent chat composer, composerDraft.ts)
//   never opt in; a scroller whose page follows its rows itself (the agent transcript,
//   `SHOWN_SCROLLER_ATTRIBUTE`) is left alone too.
// - Unsaved edits: an editor whose text nothing has saved yet marks itself (or an ancestor) with
//   `[data-cmux-unsaved-edits]`. While one is in the document each beat says `edits: true`, and an
//   input that marks or clears one beats at once, so a page that hangs right after the edit is still
//   held: the host never reloads or restarts such a page by itself.
// - Fault injection: `window.__cmuxHealthInject({fault: "hang"})` busy-loops the page for real, for
//   the host's fault-injection tests. It exists only when the host set `__cmuxHealthInjectAllowed`
//   before page code ran; no other page gets the function.
import { installScrollingMarks, lastScrolledElement, SHOWN_SCROLLER_ATTRIBUTE } from "../../scrollers";

/** Page to host, `{handled}` → null: the page is alive; `handled` is its input count so far. */
export const PAGE_HEARTBEAT_OP = "cmux.page.heartbeat";
/** Host to page, `{}` → `{saved}`: save scroll and draft now, the host reloads the page next. */
export const PAGE_SAVE_STATE_OP = "cmux.page.save_state";
/** The beat period while visible (the health contract's page policy). */
export const HEARTBEAT_MS = 2000;
/** The fault-injection push, and the flag the host sets at document start to allow it. */
export const HEALTH_INJECT_NAME = "__cmuxHealthInject";
export const HEALTH_INJECT_ALLOWED_NAME = "__cmuxHealthInjectAllowed";
/** Marks an editor (or an ancestor) holding text nothing has saved yet; the host keeps the page. */
export const UNSAVED_EDITS_ATTRIBUTE = "data-cmux-unsaved-edits";
/** Marks (or clears) the whole document as holding unsaved edits: a file page whose text is not on disk
 * yet (edited, saving, or its save failed). Synchronous, so the beat after the input sees it. */
export function markUnsavedEdits(unsaved: boolean, doc: Document | undefined = globalThis.document): void {
  const root = doc?.documentElement;
  if (!doc || !root || root.hasAttribute(UNSAVED_EDITS_ATTRIBUTE) === unsaved) return;
  root.toggleAttribute(UNSAVED_EDITS_ATTRIBUTE, unsaved);
  // An edit with no `input` event (a keymap command: undo, a moved line) still beats at once.
  doc.dispatchEvent(new (doc.defaultView ?? globalThis).Event(UNSAVED_EDITS_EVENT));
}
/** Sent on the document when ``markUnsavedEdits`` flips the mark. */
export const UNSAVED_EDITS_EVENT = "cmux-unsaved-edits";
/** sessionStorage key prefix; the page's URL follows. */
export const KEPT_STATE_PREFIX = "cmux.page.kept:";
/** How many frames a restore waits for its scroller and field to appear (about 2 s). */
const RESTORE_FRAMES = 120;

interface HealthClient {
  /** True while a parked pooled document holds its calls until its claim (pageClient.ts): no beat
   * is sent then, so none piles up. */
  readonly holding?: boolean;
  call<R>(op: string, params: unknown): Promise<R>;
  handle(op: string, handler: (params: unknown) => unknown): () => void;
}

export interface KeptState {
  scroll?: { path: string; top: number; left: number };
  /** `base`: a textarea's text as the page loaded it (its default value), so a prefilled field the
   * person edited still gets its edit back. */
  draft?: { path: string; text: string; start?: number; end?: number; base?: string };
}

const installed = new WeakSet<Document>();

export function installPageHealth(client: HealthClient, doc: Document = document): void {
  const view = doc.defaultView;
  if (!view || installed.has(doc)) return;
  installed.add(doc);
  installScrollingMarks(doc);
  // A field's text right before the person's first edit (a page's own prefill fires no beforeinput,
  // so it stays the base however late it comes).
  doc.addEventListener(
    "beforeinput",
    (event) => {
      const field = draftField(event.target as Element | null);
      if (field && isTextArea(field) && !loadedText.has(field)) loadedText.set(field, field.value);
    },
    { capture: true },
  );

  let handled = 0;
  const count = () => void handled++;
  view.addEventListener("keydown", count, { capture: true, passive: true });
  view.addEventListener("pointerdown", count, { capture: true, passive: true });

  const key = () => KEPT_STATE_PREFIX + view.location.href;
  let lastSaved = "";
  // Until the last load's state is back, an autosave would only write over it.
  let restoring = true;
  const save = () => {
    if (restoring) return;
    // Keyed by URL too: a route change at the same place still saves the new route.
    const at = key();
    const state = JSON.stringify(captureState(doc));
    if (at + "\n" + state === lastSaved) return;
    lastSaved = at + "\n" + state;
    try {
      if (state === "{}") view.sessionStorage.removeItem(at);
      else view.sessionStorage.setItem(at, state);
    } catch {
      // Storage may be full or off; the page keeps working, only the reload loses its place.
    }
  };

  let timer: number | undefined;
  let refused = false;
  const stop = () => {
    if (timer !== undefined) view.clearInterval(timer);
    timer = undefined;
  };
  let edits = false;
  const holdsEdits = () => doc.querySelector(`[${UNSAVED_EDITS_ATTRIBUTE}]`) !== null;
  const beat = () => {
    save();
    if (client.holding) return;
    edits = holdsEdits();
    client.call(PAGE_HEARTBEAT_OP, edits ? { handled, edits } : { handled }).catch((error: unknown) => {
      // An app without the op will never take one: stop for this document (stop condition).
      if ((error as { code?: unknown } | null)?.code !== "cmux.protocol.unknown_op") return;
      refused = true;
      stop();
    });
  };
  const follow = () => {
    // A hidden page saves its place even on an app that refused the beat.
    if (doc.visibilityState !== "visible") {
      stop();
      save();
      return;
    }
    if (refused || timer !== undefined) return;
    beat();
    timer = view.setInterval(beat, HEARTBEAT_MS);
  };
  // After the input's render (its mark is set or cleared by then), not at the next beat.
  const editChanged = () => {
    if (!refused && doc.visibilityState === "visible" && holdsEdits() !== edits) beat();
  };
  view.addEventListener("input", () => view.setTimeout(editChanged, 0), { capture: true, passive: true });
  doc.addEventListener(UNSAVED_EDITS_EVENT, editChanged);
  doc.addEventListener("visibilitychange", follow);
  view.addEventListener("pagehide", () => {
    stop();
    save();
  });
  client.handle(PAGE_SAVE_STATE_OP, () => {
    save();
    return { saved: true };
  });

  const target = view as unknown as Record<string, unknown>;
  if (target[HEALTH_INJECT_ALLOWED_NAME] === true) {
    target[HEALTH_INJECT_NAME] = (request: unknown) => {
      if ((request as { fault?: unknown } | null)?.fault !== "hang") return;
      // After the host's script returns, so its evaluate completes; then the page never answers.
      view.setTimeout(() => {
        for (;;) {
          // A real hang: no beats, no input handled, no replies.
        }
      }, 0);
    };
  }

  restoreState(doc, takeState(view, key()), () => (restoring = false));
  follow();
}

/** Reads the state a previous load of this URL kept (the next save replaces it). */
function takeState(view: Window, key: string): KeptState | null {
  try {
    const text = view.sessionStorage.getItem(key);
    return text === null ? null : (JSON.parse(text) as KeptState);
  } catch {
    return null;
  }
}

/** The scroll position and focused draft worth keeping now (empty when there is neither). */
export function captureState(doc: Document): KeptState {
  const state: KeptState = {};
  const scroller = lastScrolledElement(doc);
  if (
    scroller?.isConnected &&
    !scroller.hasAttribute(SHOWN_SCROLLER_ATTRIBUTE) &&
    (scroller.scrollTop > 0 || scroller.scrollLeft > 0)
  ) {
    const path = elementPath(scroller);
    if (path) state.scroll = { path, top: scroller.scrollTop, left: scroller.scrollLeft };
  }
  const field = draftField(doc.activeElement);
  if (field) {
    const path = elementPath(field);
    const text = isTextArea(field) ? field.value : (field.textContent ?? "");
    const base = isTextArea(field) ? (loadedText.get(field) ?? field.defaultValue) : "";
    // A cleared prefilled field is an edit too: kept when it differs from what the page loaded.
    if (path && (text.trim() || (base && text !== base))) {
      state.draft = { path, text };
      if (isTextArea(field)) {
        state.draft.start = field.selectionStart;
        state.draft.end = field.selectionEnd;
        if (base) state.draft.base = base;
      }
    }
  }
  return state;
}

/** Each draft field's text as the page loaded it, kept apart from `defaultValue`, which a React
 * controlled textarea keeps equal to its current value. */
const loadedText = new WeakMap<HTMLTextAreaElement, string>();

// Element checks by name, not `instanceof`: the page's constructors belong to its own window.
const isTextArea = (element: Element): element is HTMLTextAreaElement => element.localName === "textarea";
const isHTMLElement = (element: Element | null): element is HTMLElement =>
  element !== null && typeof (element as HTMLElement).focus === "function";

/** Marks a field (or an ancestor) whose draft the page keeps across a repair's reload. */
export const RESTORE_DRAFT_ATTRIBUTE = "data-cmux-restore-draft";

/** A field whose draft the page keeps: a textarea or a plain contenteditable that opted in, no
 * editor owns, and nothing saves on its own. */
function draftField(element: Element | null): HTMLElement | null {
  if (!isHTMLElement(element)) return null;
  if (!element.closest(`[${RESTORE_DRAFT_ATTRIBUTE}]`)) return null;
  if (element.closest(".ProseMirror")) return null;
  if (isTextArea(element)) return element.readOnly || element.disabled ? null : element;
  return element.isContentEditable || element.getAttribute("contenteditable") === "true" ? element : null;
}

/** Puts the kept scroll and draft back once their elements exist, giving up after `RESTORE_FRAMES`
 * or when the page navigates (the state is the old route's); then calls `done`. A person who
 * scrolls first keeps their own place. */
export function restoreState(doc: Document, state: KeptState | null, done: () => void = () => {}): void {
  const view = doc.defaultView;
  if (!view || !state || (!state.scroll && !state.draft)) return done();
  let scroll = state.scroll;
  let draft = state.draft;
  let frames = 0;
  const href = view.location.href;
  const userScrolled = () => (scroll = undefined);
  const userScrolls = ["wheel", "touchmove", "keydown", "pointerdown"] as const;
  for (const type of userScrolls) doc.addEventListener(type, userScrolled, { capture: true, passive: true });
  const finish = () => {
    for (const type of userScrolls) doc.removeEventListener(type, userScrolled, { capture: true });
    done();
  };
  const step = () => {
    if (view.location.href !== href) return finish();
    frames += 1;
    const last = frames >= RESTORE_FRAMES;
    if (scroll) {
      const element = find(doc, scroll.path);
      // Wait for the content to be tall and wide enough, unless this is the last try.
      const fits =
        element &&
        element.scrollHeight - element.clientHeight >= scroll.top &&
        element.scrollWidth - element.clientWidth >= scroll.left;
      if (element && (last || fits)) {
        element.scrollTop = scroll.top;
        element.scrollLeft = scroll.left;
        scroll = undefined;
      }
    }
    if (draft) {
      const field = draftField(find(doc, draft.path));
      if (field) {
        putDraft(field, draft);
        draft = undefined;
      }
    }
    if ((scroll || draft) && !last) view.requestAnimationFrame(step);
    else finish();
  };
  step();
}

/** Writes a draft through the field's own input path, so a React-controlled field takes it too;
 * text the person already typed since the load is never replaced. A field that still shows what the
 * page loaded into it (its kept `base`) takes the edit back. */
function putDraft(field: HTMLElement, draft: NonNullable<KeptState["draft"]>): void {
  const view = field.ownerDocument.defaultView;
  if (isTextArea(field)) {
    if (!view || (field.value && field.value !== draft.base) || field.value === draft.text) return;
    // The page's own text stays the field's base after the edit comes back.
    if (!loadedText.has(field)) loadedText.set(field, field.value);
    // The prototype's setter, not the property: React tracks the property and would drop the event.
    Object.getOwnPropertyDescriptor(view.HTMLTextAreaElement.prototype, "value")?.set?.call(field, draft.text);
    field.dispatchEvent(new view.Event("input", { bubbles: true }));
    field.focus();
    field.setSelectionRange(draft.start ?? draft.text.length, draft.end ?? draft.text.length);
    return;
  }
  if (field.textContent) return;
  field.focus();
  // The editing command goes through the element's input events, as typing does.
  field.ownerDocument.execCommand("insertText", false, draft.text);
}

function find(doc: Document, path: string): HTMLElement | null {
  try {
    const element = doc.querySelector(path);
    return isHTMLElement(element) ? element : null;
  } catch {
    return null;
  }
}

/** A selector that finds `element` again after a reload: its id when unique, else the child
 * positions from the nearest element with one (or from <html>). */
export function elementPath(element: Element): string | null {
  const doc = element.ownerDocument;
  if (element === doc.documentElement) return ":root";
  const parts: string[] = [];
  let node: Element | null = element;
  while (node && node !== doc.documentElement) {
    // An attribute selector takes any id; JSON quoting escapes its quotes and backslashes.
    const byId = node.id ? `[id=${JSON.stringify(node.id)}]` : "";
    if (byId && doc.querySelectorAll(byId).length === 1) {
      parts.unshift(byId);
      return parts.join(" > ");
    }
    const parent: Element | null = node.parentElement;
    if (!parent) return null;
    parts.unshift(`${node.localName}:nth-child(${Array.prototype.indexOf.call(parent.children, node) + 1})`);
    node = parent;
  }
  return `:root > ${parts.join(" > ")}`;
}
