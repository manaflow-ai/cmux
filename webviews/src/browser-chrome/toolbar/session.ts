// The toolbar page's omnibar session: the DOM side of AddressBarView, AddressField and
// OmnibarFieldEditor. It turns the real <input>'s events (keys, edits, IME composition, selection,
// presses, copy, cut, drops) and the host's numbered events into `OmnibarInput`s for one
// OmnibarRunner, keeps one resting state per tab slot, and is the only writer of the input (through
// the effect applier). Focus is the host's: the web view takes the keys only when the host makes it
// first responder, so a press asks for it (`requestFocus`) and the host answers with a `focus` event.
import { copyContent } from "../omnibox/copy";
import type { OmnibarFieldSurface } from "../omnibox/effect-applier";
import { HostTypoMemory } from "../omnibox/host-typo-fixup";
import type { OmnibarPresentation } from "../omnibox/presentation";
import { createOmniboxResolver, IntranetHostMemory, type BrowserOmniboxResolver } from "../omnibox/resolver";
import { droppedText } from "../omnibox/rules";
import { hasFocus, initialOmnibarState, type OmnibarState } from "../omnibox/state";
import type { OmnibarEffect, OmnibarFocusSource, OmnibarInput, OmnibarKey, TextRange } from "../omnibox/types";
import { isNewTabPage } from "../omnibox/url-display";
import { OmnibarRunner } from "./controller";
import { freshEvents } from "./events";
import { admitsKey, dispositionFor, editKindFor, omnibarKeyFor } from "./keys";
import { indexAtX, layoutChanged, wireRect, wordRangeAt, type LayoutReport } from "./layout";
import { TabSlotStore, withDraft } from "./slots";
import {
  TAB_INDEPENDENT_EVENTS,
  type StampedToolbarCommand,
  type ToolbarHostEvent,
  type ToolbarHostState,
  type ToolbarPageCommand,
  type WireRect,
} from "./wire";

/** Pointer travel (px) past which a press is a drag (AppKit's drag threshold). */
const DRAG_THRESHOLD = 3;

type Press = {
  button: 0 | 2;
  x: number;
  y: number;
  dragged: boolean;
  /** The press asked the host for focus and the focus has not come yet. */
  awaitingFocus: boolean;
  released: boolean;
};

/** The real input as the effect applier writes it (`AddressField` as `OmnibarFieldSurface`). */
class InputFieldSurface implements OmnibarFieldSurface {
  constructor(
    private readonly source: {
      input: () => HTMLInputElement | null;
      active: () => boolean;
      composing: () => boolean;
    },
  ) {}

  get isFieldEditorActive(): boolean {
    return this.source.active();
  }

  get currentText(): string {
    return this.source.input()?.value ?? "";
  }

  get currentSelection(): TextRange {
    return selectionOf(this.source.input());
  }

  get hasMarkedText(): boolean {
    return this.source.composing();
  }

  write(text: string): void {
    const input = this.source.input();
    if (input && input.value !== text) input.value = text;
  }

  select(range: TextRange): void {
    this.source.input()?.setSelectionRange(range.location, range.location + range.length);
  }
}

function selectionOf(input: HTMLInputElement | null): TextRange {
  if (!input) return { location: 0, length: 0 };
  const start = input.selectionStart ?? 0;
  const end = input.selectionEnd ?? start;
  return { location: start, length: Math.max(0, end - start) };
}

/** What the page draws, as one immutable value per change (React reads nothing else). */
export type ToolbarSnapshot = {
  host: ToolbarHostState | null;
  state: OmnibarState;
  presentation: OmnibarPresentation;
  chipDrag: { url: string; title: string | null } | null;
};

export class ToolbarSession {
  host: ToolbarHostState | null = null;
  readonly runner: OmnibarRunner;
  private snapshot: ToolbarSnapshot | null = null;
  private readonly listeners = new Set<() => void>();
  private input: HTMLInputElement | null = null;
  /** The field editor is active: the host gave the web view the keys and the input has them. */
  private editorActive = false;
  private composing = false;
  private compositionStart = 0;
  private compositionText = "";
  private ownDrag = false;
  private blurring = false;
  private press: Press | null = null;
  /** A release that came before the focus the press asked for: replayed once it comes. */
  private pendingRelease = false;
  private readonly slots = new TabSlotStore();
  private tab: string | null = null;
  /**
   * The highest query generation any tab of this page used. A restored tab resumes above it, so a
   * generation is never reused across tabs and a late delivery for another tab's query is stale.
   */
  private queryEpoch = 0;
  private lastSeq = 0;
  private readonly typoMemory = new HostTypoMemory();
  private readonly intranetHosts = new IntranetHostMemory();
  private intranetKey = "";
  private resolverKey = "";
  private resolver: BrowserOmniboxResolver = createOmniboxResolver({
    hostTypoMemory: this.typoMemory,
    intranetHosts: this.intranetHosts,
  });
  private lastLayout: LayoutReport | null = null;
  private measureContext: CanvasRenderingContext2D | null = null;

  /** The host binding of the state applied last: every command carries it (`ToolbarHostState.binding`). */
  private binding: number | null = null;
  /**
   * The host let the shown tab go (`forgetTab` for it, under binding `binding`): the next switch keeps
   * no slot for it, and the same tab bound again (a newer binding) rests on the draft it brings, as a
   * tab new to this page.
   */
  private forgotten: { binding: number | null } | null = null;

  /** Posts `command` stamped with the binding it was made under. */
  readonly post = (command: ToolbarPageCommand): void => {
    this.postStamped({ ...command, binding: this.binding });
  };

  constructor(private readonly postStamped: (command: StampedToolbarCommand) => void) {
    this.runner = new OmnibarRunner(initialOmnibarState(), {
      field: new InputFieldSurface({
        input: () => this.input,
        active: () => this.editorActive,
        composing: () => this.composing,
      }),
      post: (command) => this.post(command),
      resolver: () => this.resolver,
      upward: () => this.host?.omnibar.upward ?? false,
      labelForEngine: (engine) => {
        const format = this.host?.omnibar.searchKeywordFormat;
        return format ? format.replace(/%(?:1\$)?@/, engine) : `Search ${engine}`;
      },
      onEffect: (effect) => this.runLocally(effect),
      onStep: () => this.changed(),
      tab: () => this.tab,
    });
  }

  // MARK: Store

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): ToolbarSnapshot => {
    this.snapshot ??= {
      host: this.host,
      state: this.state,
      presentation: this.presentation,
      chipDrag: this.chipDrag,
    };
    return this.snapshot;
  };

  private changed(): void {
    this.snapshot = null;
    for (const listener of this.listeners) listener();
  }

  get state(): OmnibarState {
    return this.runner.state;
  }

  get presentation(): OmnibarPresentation {
    return this.runner.presentation;
  }

  private get readOnly(): boolean {
    return this.host?.omnibar.readOnly ?? false;
  }

  /** The address the chip drags out at rest (none for an empty bar or the New Tab page). */
  get chipDrag(): { url: string; title: string | null } | null {
    const url = this.state.pageURL;
    if (hasFocus(this.state) || !url || isNewTabPage(url)) return null;
    return { url, title: this.host?.title ?? null };
  }

  // MARK: Host state

  applyHostState(next: ToolbarHostState): void {
    const previous = this.host;
    this.host = next;
    this.binding = next.binding ?? null;
    this.updateResolver(next);
    if (this.input) this.input.readOnly = next.omnibar.readOnly;
    const options = { home: next.omnibar.home, showsFullURLs: next.omnibar.showFullURLs };
    if (this.tab === null) {
      this.tab = next.tab;
      this.runner.restore(withDraft(initialOmnibarState(next.url, options), next.draft));
    } else if (next.tab !== this.tab || (this.forgotten && this.forgotten.binding !== this.binding)) {
      this.switchTab(next, options);
    } else {
      if (previous && next.url !== previous.url) this.send({ type: "pageURLChanged", url: next.url });
      if (next.omnibar.showFullURLs !== this.state.showsFullURLs) {
        this.send({ type: "showFullURLsChanged", full: next.omnibar.showFullURLs });
      }
      const engine = previous?.omnibar.searchEngine;
      const now = next.omnibar.searchEngine;
      if (engine && (engine.id !== now.id || engine.queryTemplate !== now.queryTemplate)) {
        this.send({ type: "searchEngineChanged" });
      }
    }
    this.handleEvents(next);
    this.changed();
  }

  /**
   * Leaves the shown tab (its omnibar rests in its slot) and shows `next.tab`'s: its slot here, else
   * the draft it brought from another pane.
   */
  private switchTab(next: ToolbarHostState, options: { home: string; showsFullURLs: boolean }): void {
    if (hasFocus(this.state)) this.loseFocus();
    // The outgoing tab's query stops on the host; its deliveries already queued are stale below.
    this.post({ type: "effect", effect: { type: "cancelQuery" } });
    this.queryEpoch = Math.max(this.queryEpoch, this.state.generation) + 1;
    if (this.tab !== null && !this.forgotten) this.slots.set(this.tab, this.state);
    this.forgotten = null;
    this.tab = next.tab;
    const saved = this.slots.get(next.tab);
    const resting = saved
      ? { ...saved, home: options.home }
      : withDraft(initialOmnibarState(next.url, options), next.draft);
    this.runner.restore({ ...resting, generation: this.queryEpoch });
    this.send({ type: "pageURLChanged", url: next.url });
    if (this.state.showsFullURLs !== options.showsFullURLs) {
      this.send({ type: "showFullURLsChanged", full: options.showsFullURLs });
    }
  }

  private updateResolver(next: ToolbarHostState): void {
    const config = next.omnibar;
    for (const host of config.fixedTypoHosts) this.typoMemory.recordFix(host);
    const intranetKey = config.intranetHosts.join("\n");
    if (intranetKey !== this.intranetKey) {
      this.intranetKey = intranetKey;
      this.intranetHosts.replaceAll(config.intranetHosts);
    }
    const key = JSON.stringify([config.searchEngine, config.keywords, config.home, config.allowsChromiumSchemes]);
    if (key === this.resolverKey) return;
    this.resolverKey = key;
    this.resolver = createOmniboxResolver({
      searchEngine: config.searchEngine,
      keywords: config.keywords,
      homeDirectory: config.home,
      allowsChromiumSchemes: config.allowsChromiumSchemes,
      hostTypoMemory: this.typoMemory,
      intranetHosts: this.intranetHosts,
    });
  }

  private handleEvents(next: ToolbarHostState): void {
    const { fresh, lastSeq } = freshEvents(next.events, this.lastSeq);
    if (fresh.length === 0) return;
    this.lastSeq = lastSeq;
    for (const { event, binding } of fresh) {
      // A tab-scoped request queued for a tab the host showed before this one: never this tab's.
      if (binding != null && binding !== this.binding && !TAB_INDEPENDENT_EVENTS.has(event.kind)) continue;
      this.handleEvent(event);
    }
    this.post({ type: "ack", seq: lastSeq });
  }

  private handleEvent(event: ToolbarHostEvent): void {
    switch (event.kind) {
      case "focus":
        return this.grantFocus(event.source);
      case "blur":
        return this.loseFocus();
      case "key":
        if (admitsKey(event.key, this.readOnly)) this.send({ type: "key", key: event.key });
        return;
      case "suggestions":
        this.send({ type: "suggestions", generation: event.generation, rows: event.rows });
        return;
      case "moreSuggestions":
        this.send({
          type: "moreSuggestions",
          generation: event.generation,
          rows: event.rows,
          capacity: event.capacity,
        });
        return;
      case "rowHover":
        this.send({ type: "rowHover", row: event.row, pointer: event.pointer });
        return;
      case "rowClick":
        this.commitComposition();
        this.send({ type: "rowClick", row: event.row, disposition: dispositionFor(event.modifiers), shown: event.shown });
        return;
      case "showPageURL":
        this.send({ type: "pageURLChanged", url: this.host?.url ?? null });
        return;
      case "pasteAndGo":
        if (this.readOnly) return;
        this.commitComposition();
        this.send({ type: "pasteAndGo", text: event.text });
        return;
      case "dropped":
        this.acceptDrop(event.text);
        return;
      case "forgetTab":
        this.slots.delete(event.tab);
        // The shown tab left (`release` keeps the slot until the next binding): no slot is kept for it.
        if (event.tab === this.tab) this.forgotten = { binding: this.binding };
        return;
      case "debugType":
        return this.debugType(event.text, event.commit);
    }
  }

  // MARK: Focus

  /** The host gave the web view the keys (`AddressField.becomeFirstResponder` -> `fieldDidFocus`). */
  private grantFocus(source: OmnibarFocusSource): void {
    const wasActive = this.editorActive;
    this.editorActive = true;
    this.input?.focus({ preventScroll: true });
    if (hasFocus(this.state)) {
      // Cmd-L while focused: the full URL, all selected again.
      if (source === "keyboard") this.send({ type: "key", key: { kind: "focusLocation" } });
      else if (!wasActive) this.runner.applier.apply(this.presentation);
    } else {
      this.send({ type: "focusGained", source });
    }
    if (this.press) this.press.awaitingFocus = false;
    if (this.pendingRelease) this.flushRelease();
  }

  /** The field editor ended (the web view resigned, or the tab left): `controlTextDidEndEditing`. */
  private loseFocus(): void {
    if (this.pendingRelease) this.flushRelease();
    this.commitComposition();
    this.editorActive = false;
    if (this.input && document.activeElement === this.input) {
      this.blurring = true;
      this.input.blur();
      this.blurring = false;
    }
    if (hasFocus(this.state)) this.send({ type: "focusLost" });
    else this.runner.applier.apply(this.presentation);
  }

  // MARK: The input

  /** React's ref for the field's input; listeners attach once per element. */
  attachInput = (input: HTMLInputElement | null): void => {
    if (!input || input === this.input) return;
    this.input = input;
    input.readOnly = this.readOnly;
    const on = <K extends keyof HTMLElementEventMap>(type: K, handler: (event: HTMLElementEventMap[K]) => void) =>
      input.addEventListener(type, handler);
    on("keydown", (event) => this.keyDown(event));
    on("beforeinput", (event) => this.beforeInput(event));
    on("input", (event) => this.inputEvent(event as InputEvent));
    on("compositionstart", () => {
      this.composing = true;
      this.compositionStart = Math.min(input.selectionStart ?? 0, input.selectionEnd ?? 0);
      this.compositionText = "";
    });
    on("compositionupdate", (event) => {
      this.compositionText = event.data ?? "";
    });
    on("compositionend", () => {
      this.composing = false;
      this.compositionText = "";
      // `unmarkText`: the commit reaches the state machine as an edit.
      this.reportField("insert");
    });
    on("copy", (event) => this.copy(event, false));
    on("cut", (event) => this.copy(event, true));
    on("dragstart", () => {
      this.ownDrag = true;
    });
    on("dragend", () => {
      this.ownDrag = false;
    });
    on("blur", () => {
      // The host's `blur` event ends editing when the web view resigns; a blur inside a page that
      // keeps the keys (focus moved to another element) ends it here.
      if (this.blurring || !this.editorActive || !document.hasFocus()) return;
      this.loseFocus();
    });
    const page = input.ownerDocument;
    page.addEventListener("selectionchange", () => {
      if (page.activeElement !== input || this.press || this.composing) return;
      this.reportField(null);
    });
    const bar = input.closest<HTMLElement>(".bc-omnibar");
    if (bar) this.attachDrops(bar);
    // A press around the text never moves DOM focus or starts a selection; the press itself
    // is `fieldMouseDown`'s.
    input.closest<HTMLElement>(".bc-field")?.addEventListener("mousedown", (event) => {
      if (event.target !== input && event.button === 0) event.preventDefault();
    });
    // A focus the host granted before React mounted the input (the first state's queued `focus`,
    // a Cmd-L while the page loaded) reached no element: the keys go to the input now, then the
    // applier places the text and selection in the focused field.
    if (this.editorActive) input.focus({ preventScroll: true });
    this.runner.applier.apply(this.presentation);
  };

  private selection(): TextRange {
    return selectionOf(this.input);
  }

  /** Reports what the input holds now; the applier's own writes are echoes and are dropped. */
  private reportField(kind: "insert" | "delete" | "paste" | null): void {
    const input = this.input;
    if (!input || this.runner.applying || !this.editorActive) return;
    const marked = this.composing ? { location: this.compositionStart, length: this.compositionText.length } : null;
    this.send({ type: "fieldChanged", field: { text: input.value, selection: this.selection(), marked }, kind });
  }

  /** A row click or Paste and Go ends a composition first, as a click elsewhere does. */
  private commitComposition(): void {
    if (!this.composing || !this.input) return;
    this.composing = false;
    this.compositionText = "";
    this.reportField("insert");
  }

  private keyDown(event: KeyboardEvent): void {
    if (event.isComposing || event.keyCode === 229) return;
    const selection = this.selection();
    const key = omnibarKeyFor(
      { key: event.key, meta: event.metaKey, shift: event.shiftKey, alt: event.altKey, ctrl: event.ctrlKey },
      {
        popupOpen: this.presentation.rows.length > 0,
        caretAtStart: selection.location === 0 && selection.length === 0,
      },
    );
    if (!key) return;
    const always = key.kind === "undo" || key.kind === "redo";
    if (!admitsKey(key, this.readOnly)) {
      if (always) event.preventDefault();
      return;
    }
    // The state machine owns undo: the input's own never runs.
    if (this.sendKey(key) || always) event.preventDefault();
  }

  private sendKey(key: OmnibarKey): boolean {
    return this.send({ type: "key", key });
  }

  private beforeInput(event: InputEvent): void {
    if (event.inputType === "historyUndo" || event.inputType === "historyRedo") {
      event.preventDefault();
      this.sendKey({ kind: event.inputType === "historyUndo" ? "undo" : "redo" });
    }
  }

  private inputEvent(event: InputEvent): void {
    this.reportField(this.composing ? "insert" : editKindFor(event.inputType));
  }

  /** Copy and Cut with the omnibox's adjustments (`OmnibarFieldEditor.copy`). */
  private copy(event: ClipboardEvent, cut: boolean): void {
    const content = copyContent(this.state, this.resolver);
    if (!content || !event.clipboardData) return;
    event.preventDefault();
    event.clipboardData.setData("text/plain", content.text);
    if (content.url) event.clipboardData.setData("text/uri-list", content.url);
    const input = this.input;
    if (!cut || !input || this.readOnly) return;
    const { location, length } = this.selection();
    input.value = input.value.slice(0, location) + input.value.slice(location + length);
    input.setSelectionRange(location, location);
    this.reportField("delete");
  }

  // MARK: Drops

  private attachDrops(bar: HTMLElement): void {
    const accepts = (event: DragEvent) =>
      !this.ownDrag &&
      !this.readOnly &&
      !!event.dataTransfer &&
      (event.dataTransfer.types.includes("text/uri-list") || event.dataTransfer.types.includes("text/plain"));
    const over = (event: DragEvent) => {
      if (!accepts(event) || !event.dataTransfer) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    };
    bar.addEventListener("dragenter", over);
    bar.addEventListener("dragover", over);
    bar.addEventListener("drop", (event) => {
      if (!accepts(event) || !event.dataTransfer) return;
      const text = dropText(event.dataTransfer);
      if (text === null) return;
      // The bar takes it as a whole, never an insert at the pointer.
      event.preventDefault();
      this.acceptDrop(text);
    });
  }

  /** `AddressBarView.acceptDrop`: focuses the field and hands the text to the state machine. */
  private acceptDrop(text: string): boolean {
    if (this.readOnly) return false;
    if (!this.editorActive) {
      this.post({ type: "requestFocus" });
      this.editorActive = true;
      this.input?.focus({ preventScroll: true });
    }
    if (!hasFocus(this.state)) this.send({ type: "focusGained", source: "programmatic" });
    return this.send({ type: "dropped", text });
  }

  // MARK: Presses

  /**
   * A press on the field's area (`AddressBarView.mouseDown`, `AddressField.mouseDown`). A mouse
   * event, not a pointer event: only `mousedown.detail` carries the platform click count.
   */
  fieldMouseDown = (event: MouseEvent | { nativeEvent: MouseEvent }): void => {
    const native = "nativeEvent" in event ? event.nativeEvent : event;
    const input = this.input;
    if (!input || (native.button !== 0 && native.button !== 2)) return;
    if (this.pendingRelease) this.flushRelease();
    const onInput = native.target === input;
    const focused = this.editorActive && hasFocus(this.state);
    const clicks = Math.max(1, native.detail);
    const right = native.button === 2;
    let word: TextRange | null = null;
    if (!right && focused && onInput && clicks === 1 && this.state.phase === "focused" && this.state.elided) {
      word = wordRangeAt(input.value, this.indexAt(native.clientX));
    }
    this.send({ type: "fieldMouseDown", clickCount: clicks, button: right ? "right" : "left", word });
    if (!focused) {
      this.post({ type: "requestFocus" });
      // The bar around the text: no DOM focus move; the host's focus places it.
      if (!onInput && !right) native.preventDefault();
    } else if (!onInput && !right) {
      // Around the text while editing: the caret at the nearest end.
      native.preventDefault();
      const index = native.clientX < input.getBoundingClientRect().left ? 0 : input.value.length;
      input.setSelectionRange(index, index);
    }
    const press: Press = {
      button: right ? 2 : 0,
      x: native.screenX,
      y: native.screenY,
      dragged: false,
      awaitingFocus: !focused,
      released: false,
    };
    this.press = press;
    const move = (moved: PointerEvent) => {
      if (Math.hypot(moved.screenX - press.x, moved.screenY - press.y) > DRAG_THRESHOLD) press.dragged = true;
    };
    const release = () => {
      window.removeEventListener("pointermove", move, true);
      window.removeEventListener("pointerup", release, true);
      window.removeEventListener("pointercancel", release, true);
      window.removeEventListener("contextmenu", release, true);
      this.release(press);
    };
    window.addEventListener("pointermove", move, true);
    window.addEventListener("pointerup", release, true);
    window.addEventListener("pointercancel", release, true);
    // The native context menu opens on the press; its release may never reach the page.
    if (right) window.addEventListener("contextmenu", release, true);
  };

  private release(press: Press): void {
    if (press.released) return;
    press.released = true;
    if (press.awaitingFocus && !this.editorActive) {
      this.pendingRelease = true;
      return;
    }
    this.flushRelease();
  }

  /** The press ended: the final selection, the drag, then the release (`OmnibarFieldEditor.mouseDown`). */
  private flushRelease(): void {
    const press = this.press;
    this.pendingRelease = false;
    this.press = null;
    this.reportField(null);
    if (press?.dragged) this.send({ type: "fieldMouseDragged" });
    this.send({ type: "fieldMouseUp" });
  }

  /** The caret index under `clientX` in the input's text. */
  private indexAt(clientX: number): number {
    const input = this.input;
    if (!input) return 0;
    const style = getComputedStyle(input);
    this.measureContext ??= document.createElement("canvas").getContext("2d");
    const context = this.measureContext;
    if (!context) return 0;
    context.font = style.font || `${style.fontSize} ${style.fontFamily}`;
    const x = clientX - input.getBoundingClientRect().left - parseFloat(style.paddingLeft || "0") + input.scrollLeft;
    return indexAtX(input.value, x, (prefix) => context.measureText(prefix).width);
  }

  // MARK: Debug

  /** `debug.omnibar_type`: types `text` through the field's edit path, then (with `commit`) Return. */
  private debugType(text: string, commit: boolean): void {
    this.grantFocus("keyboard");
    const input = this.input;
    if (!input) return;
    for (const character of text) {
      const { location, length } = this.selection();
      input.value = input.value.slice(0, location) + character + input.value.slice(location + length);
      input.setSelectionRange(location + character.length, location + character.length);
      this.reportField("insert");
    }
    if (commit) this.sendKey({ kind: "enter", disposition: "currentTab" });
  }

  // MARK: Steps and effects

  private send(input: OmnibarInput): boolean {
    return this.runner.send(input);
  }

  private runLocally(effect: OmnibarEffect): void {
    switch (effect.type) {
      case "hostTypoFixed":
        this.typoMemory.recordFix(effect.typedHost);
        return;
      case "copyAnswer":
        void navigator.clipboard?.writeText(effect.text).catch(() => undefined);
        return;
      default:
        return;
    }
  }

  // MARK: Layout

  /** Sends where the controls are, when anything moved (`layout`). */
  reportLayout(root: HTMLElement, layout: Omit<LayoutReport, "rects">): void {
    const rects: Record<string, WireRect> = {};
    const rectOf = (element: Element) => {
      const box = element.getBoundingClientRect();
      return wireRect(box.left, box.top, box.width, box.height);
    };
    for (const element of root.querySelectorAll<HTMLElement>("[data-rect]")) {
      const key = element.dataset.rect;
      if (key) rects[key] = rectOf(element);
    }
    // The I-beam area: from the chip to the first badge (or the star, or the bar's end).
    const bar = root.querySelector(".bc-omnibar");
    const field = root.querySelector(".bc-field");
    if (bar && field) {
      const barBox = bar.getBoundingClientRect();
      const start = field.getBoundingClientRect().left;
      const trailing = bar.querySelector(".bc-badge, .bc-star");
      const end = trailing ? trailing.getBoundingClientRect().left : barBox.right;
      rects.text = wireRect(start, barBox.top, Math.max(0, end - start), barBox.height);
    }
    const report: LayoutReport = { rects, ...layout };
    if (!layoutChanged(this.lastLayout, report)) return;
    this.lastLayout = report;
    this.post({ type: "layout", ...report });
  }
}

/** What a drop puts in the box: its first URL, else its text; null for neither (`dropText(from:)`). */
export function dropText(data: Pick<DataTransfer, "getData">): string | null {
  const url = data
    .getData("text/uri-list")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line !== "" && !line.startsWith("#"));
  if (url) return url;
  const text = data.getData("text/plain");
  return text && droppedText(text) ? text : null;
}
