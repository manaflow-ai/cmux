// The toolbar page's pure parts: keys, dispositions, tab slots, event seqs, layout diffs, the
// runner's queue and status, and the chip mapping.
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { OmnibarFieldSurface } from "../omnibox/effect-applier";
import { initialOmnibarState } from "../omnibox/state";
import { testResolver } from "../omnibox/testing";
import type { TextRange } from "../omnibox/types";
import { resolveLayout, TOOLBAR_METRICS } from "../ui/toolbarModel";
import { OmnibarRunner } from "./controller";
import { freshEvents } from "./events";
import { admitsKey, dispositionFor, editKindFor, omnibarKeyFor, type KeyPress } from "./keys";
import { indexAtX, layoutChanged, wireRect, wordRangeAt, type LayoutReport } from "./layout";
import { ToolbarSession } from "./session";
import { draftOf, TabSlotStore } from "./slots";
import { barFills, chipFor, emphasisFor, starFor, wireCommand } from "./view";
import type { OmnibarDraft, ToolbarHostEvent, ToolbarHostState, ToolbarPageCommand } from "./wire";

const press = (key: string, modifiers: Partial<KeyPress> = {}): KeyPress => ({
  key,
  meta: false,
  shift: false,
  alt: false,
  ctrl: false,
  ...modifiers,
});
const closed = { popupOpen: false, caretAtStart: false };
const open = { popupOpen: true, caretAtStart: false };

describe("dispositions (Disposition(flags))", () => {
  test("modifiers pick where a commit opens", () => {
    expect(dispositionFor({ meta: false, shift: false, alt: false })).toBe("currentTab");
    expect(dispositionFor({ meta: true, shift: false, alt: false })).toBe("newBackgroundTab");
    expect(dispositionFor({ meta: true, shift: true, alt: false })).toBe("newForegroundTab");
    expect(dispositionFor({ meta: false, shift: false, alt: true })).toBe("newForegroundTab");
    expect(dispositionFor({ meta: false, shift: true, alt: false })).toBe("newWindow");
    expect(dispositionFor({ meta: true, shift: false, alt: true })).toBe("newBackgroundTab");
  });
});

describe("keys (OmnibarFieldEditor, doCommandBy)", () => {
  test("Return with modifiers and Control-Return", () => {
    expect(omnibarKeyFor(press("Enter"), closed)).toEqual({ kind: "enter", disposition: "currentTab" });
    expect(omnibarKeyFor(press("Enter", { meta: true }), closed)).toEqual({
      kind: "enter",
      disposition: "newBackgroundTab",
    });
    expect(omnibarKeyFor(press("Enter", { shift: true }), closed)).toEqual({ kind: "enter", disposition: "newWindow" });
    expect(omnibarKeyFor(press("Enter", { ctrl: true }), closed)).toEqual({
      kind: "enterAddingTLD",
      disposition: "currentTab",
    });
  });

  test("arrows, Tab, Escape, Home", () => {
    expect(omnibarKeyFor(press("ArrowDown"), closed)).toEqual({ kind: "down" });
    expect(omnibarKeyFor(press("ArrowUp"), closed)).toEqual({ kind: "up" });
    expect(omnibarKeyFor(press("ArrowDown", { shift: true }), closed)).toBeNull();
    expect(omnibarKeyFor(press("ArrowUp", { meta: true }), closed)).toBeNull();
    expect(omnibarKeyFor(press("Tab"), closed)).toEqual({ kind: "tab" });
    expect(omnibarKeyFor(press("Tab", { shift: true }), closed)).toEqual({ kind: "backTab" });
    expect(omnibarKeyFor(press("Escape"), closed)).toEqual({ kind: "escape" });
    expect(omnibarKeyFor(press("Home"), closed)).toEqual({ kind: "home", extend: false });
    expect(omnibarKeyFor(press("Home", { shift: true }), closed)).toEqual({ kind: "home", extend: true });
  });

  test("Cmd-A, undo and redo, Shift-Delete", () => {
    expect(omnibarKeyFor(press("a", { meta: true }), closed)).toEqual({ kind: "selectAll" });
    expect(omnibarKeyFor(press("z", { meta: true }), closed)).toEqual({ kind: "undo" });
    expect(omnibarKeyFor(press("Z", { meta: true, shift: true }), closed)).toEqual({ kind: "redo" });
    expect(omnibarKeyFor(press("Delete", { shift: true }), closed)).toEqual({ kind: "deleteSuggestion" });
    expect(omnibarKeyFor(press("Delete"), closed)).toBeNull();
    expect(omnibarKeyFor(press("a"), closed)).toBeNull();
  });

  test("Backspace only at the start", () => {
    expect(omnibarKeyFor(press("Backspace"), closed)).toBeNull();
    expect(omnibarKeyFor(press("Backspace"), { popupOpen: false, caretAtStart: true })).toEqual({
      kind: "backspaceAtStart",
    });
    expect(omnibarKeyFor(press("Backspace", { alt: true }), { popupOpen: false, caretAtStart: true })).toBeNull();
  });

  test("Ctrl-N/P/J/K move the open list only", () => {
    expect(omnibarKeyFor(press("n", { ctrl: true }), open)).toEqual({ kind: "down" });
    expect(omnibarKeyFor(press("j", { ctrl: true }), open)).toEqual({ kind: "down" });
    expect(omnibarKeyFor(press("p", { ctrl: true }), open)).toEqual({ kind: "up" });
    expect(omnibarKeyFor(press("k", { ctrl: true }), open)).toEqual({ kind: "up" });
    expect(omnibarKeyFor(press("n", { ctrl: true }), closed)).toBeNull();
  });

  test("a read-only bar admits only the keys that select or leave", () => {
    expect(admitsKey({ kind: "escape" }, true)).toBe(true);
    expect(admitsKey({ kind: "selectAll" }, true)).toBe(true);
    expect(admitsKey({ kind: "focusLocation" }, true)).toBe(true);
    expect(admitsKey({ kind: "home", extend: true }, true)).toBe(true);
    expect(admitsKey({ kind: "enter", disposition: "currentTab" }, true)).toBe(false);
    expect(admitsKey({ kind: "undo" }, true)).toBe(false);
    expect(admitsKey({ kind: "undo" }, false)).toBe(true);
  });

  test("edit kinds from inputType", () => {
    expect(editKindFor("insertText")).toBe("insert");
    expect(editKindFor("insertFromPaste")).toBe("paste");
    expect(editKindFor("deleteContentBackward")).toBe("delete");
    expect(editKindFor("deleteByCut")).toBe("delete");
    expect(editKindFor("insertCompositionText")).toBe("insert");
  });
});

describe("tab slots", () => {
  test("stores, forgets and evicts the least recently used", () => {
    const store = new TabSlotStore(2);
    const a = initialOmnibarState("https://a.example/");
    const b = initialOmnibarState("https://b.example/");
    const c = initialOmnibarState("https://c.example/");
    store.set("a", a);
    store.set("b", b);
    expect(store.get("a")).toBe(a);
    store.set("c", c);
    expect(store.has("b")).toBe(false);
    expect(store.get("a")).toBe(a);
    expect(store.get("c")).toBe(c);
    store.delete("a");
    expect(store.get("a")).toBeUndefined();
    expect(store.size).toBe(1);
  });
});

describe("host events", () => {
  test("each seq once, in order", () => {
    const events = [
      { seq: 3, event: "c" },
      { seq: 1, event: "a" },
      { seq: 2, event: "b" },
    ];
    const first = freshEvents(events, 0);
    expect(first.fresh.map((entry) => entry.event)).toEqual(["a", "b", "c"]);
    expect(first.lastSeq).toBe(3);
    const again = freshEvents([...events, { seq: 4, event: "d" }], first.lastSeq);
    expect(again.fresh.map((entry) => entry.event)).toEqual(["d"]);
    expect(freshEvents(events, 3)).toEqual({ fresh: [], lastSeq: 3 });
  });
});

describe("layout", () => {
  const report = (rects: LayoutReport["rects"], collapse = 0): LayoutReport => ({
    rects,
    showsForward: true,
    visiblePinned: 0,
    collapse,
  });

  test("sends only when something moved", () => {
    const base = report({ back: wireRect(2, 0, 28, 28) });
    expect(layoutChanged(null, base)).toBe(true);
    expect(layoutChanged(base, report({ back: wireRect(2.01, 0, 28, 28) }))).toBe(false);
    expect(layoutChanged(base, report({ back: wireRect(3, 0, 28, 28) }))).toBe(true);
    expect(layoutChanged(base, report({ back: wireRect(2, 0, 28, 28), star: wireRect(0, 0, 20, 20) }))).toBe(true);
    expect(layoutChanged(base, report({ back: wireRect(2, 0, 28, 28) }, 1))).toBe(true);
  });

  test("resolveLayout takes the host's metrics and resolved buttons", () => {
    const buttons = [
      { id: "designMode", collapseLevel: 1 },
      { id: "downloads", collapseLevel: 2 },
      { id: "overflow", collapseLevel: null },
    ];
    expect(resolveLayout(1000, buttons, 0, false).collapse).toBe(0);
    const narrow = resolveLayout(250, buttons, 0, false);
    expect(narrow.collapse).toBe(2);
    const big = { ...TOOLBAR_METRICS, button: 40, minimumAddress: 300 };
    expect(resolveLayout(500, buttons, 0, false).collapse).toBe(0);
    expect(resolveLayout(500, buttons, 0, false, big).collapse).toBe(2);
  });

  test("the caret index under a point", () => {
    const measure = (prefix: string) => prefix.length * 10;
    expect(indexAtX("example.com", -5, measure)).toBe(0);
    expect(indexAtX("example.com", 34, measure)).toBe(3);
    expect(indexAtX("example.com", 36, measure)).toBe(4);
    expect(indexAtX("example.com", 500, measure)).toBe(11);
  });

  test("the word at a caret", () => {
    const text = "docs.example.com/guide";
    expect(wordRangeAt(text, 7)).toEqual({ location: 5, length: 7 });
    expect(wordRangeAt(text, 0)).toEqual({ location: 0, length: 4 });
    expect(wordRangeAt(text, 16)).toEqual({ location: 13, length: 3 });
    expect(wordRangeAt("", 0)).toBeNull();
  });
});

class FakeField implements OmnibarFieldSurface {
  isFieldEditorActive = false;
  currentText = "";
  currentSelection: TextRange = { location: 0, length: 0 };
  hasMarkedText = false;
  write(text: string): void {
    this.currentText = text;
  }
  select(range: TextRange): void {
    this.currentSelection = range;
  }
}

describe("runner (OmnibarController)", () => {
  function make() {
    const field = new FakeField();
    const sent: ToolbarPageCommand[] = [];
    const runner = new OmnibarRunner(initialOmnibarState("https://example.com/"), {
      field,
      post: (command) => sent.push(command),
      resolver: () => testResolver(),
      upward: () => false,
    });
    return { field, sent, runner };
  }

  test("a step applies the field, then sends its effects in order, then the status", () => {
    const { field, sent, runner } = make();
    field.isFieldEditorActive = true;
    runner.send({ type: "focusGained", source: "keyboard" });
    expect(field.currentText).toBe("https://example.com/");
    expect(sent.map((command) => command.type)).toEqual(["effect", "status"]);
    expect(sent[0]).toEqual({ type: "effect", effect: { type: "began" } });
    const status = sent[1] as Extract<ToolbarPageCommand, { type: "status" }>;
    expect(status.phase).toBe("focused");
    expect(status.selection).toEqual([0, "https://example.com/".length]);
  });

  test("no status when nothing it carries changed", () => {
    const { sent, runner } = make();
    runner.send({ type: "focusLost" });
    expect(sent.filter((command) => command.type === "status")).toHaveLength(1);
    runner.send({ type: "focusLost" });
    expect(sent.filter((command) => command.type === "status")).toHaveLength(1);
  });

  test("inputs sent during a step queue behind it", () => {
    const field = new FakeField();
    const order: string[] = [];
    let runner: OmnibarRunner | null = null;
    runner = new OmnibarRunner(initialOmnibarState("https://example.com/"), {
      field,
      post: (command) => {
        if (command.type === "effect") {
          order.push(command.effect.type);
          // A began effect that blurs at once (a re-entrant focus change).
          if (command.effect.type === "began") expect(runner?.send({ type: "focusLost" })).toBe(false);
        }
      },
      resolver: () => testResolver(),
      upward: () => false,
    });
    runner.send({ type: "focusGained", source: "keyboard" });
    expect(order).toEqual(["began", "ended"]);
    expect(runner.state.phase).toBe("idle");
  });

  test("rows go to the host as a popup command", () => {
    const { field, sent, runner } = make();
    field.isFieldEditorActive = true;
    runner.send({ type: "focusGained", source: "keyboard" });
    field.currentText = "exa";
    field.currentSelection = { location: 3, length: 0 };
    runner.send({
      type: "fieldChanged",
      field: { text: "exa", selection: { location: 3, length: 0 } },
      kind: "insert",
    });
    const query = sent.find((command) => command.type === "effect" && command.effect.type === "query");
    expect(query).toBeDefined();
    const generation = runner.state.generation;
    runner.send({
      type: "suggestions",
      generation,
      rows: [{ kind: "navigate", title: "example.com", detail: "", url: "https://example.com/", score: 1000 }],
    });
    const popup = [...sent].reverse().find((command) => command.type === "popup");
    expect(popup).toMatchObject({ type: "popup", highlighted: 0, upward: false });
    runner.send({ type: "key", key: { kind: "escape" } });
    expect([...sent].reverse().find((command) => command.type === "popup")).toMatchObject({ rows: [] });
  });
});

describe("view", () => {
  test("the bar's tonal fill always draws, over the theme background at the coverage", () => {
    const step = (percent: number, under: string) => `color-mix(in srgb, var(--ds-color-fg) ${percent}%, ${under})`;
    const surface = (percent: number) => `color-mix(in srgb, var(--ds-color-surface) ${percent}%, transparent)`;
    // 0 (the default): as see-through as the window, the step and its hover still drawn.
    expect(barFills({ material: "off", backgroundOpacity: 0 })).toEqual({
      fill: step(7, "transparent"),
      hover: step(10, "transparent"),
    });
    // 0.5: half the theme background under the step.
    expect(barFills({ material: "off", backgroundOpacity: 0.5 })).toEqual({
      fill: step(7, surface(50)),
      hover: step(10, surface(50)),
    });
    // 1: the theme background covers the window fully; the step sits over it.
    expect(barFills({ material: "off", backgroundOpacity: 1 })).toEqual({
      fill: step(7, surface(100)),
      hover: step(10, surface(100)),
    });
    // The host's legibility floor raises the coverage; out-of-range values clamp.
    expect(barFills({ material: "off", backgroundOpacity: 0, coverage: 0.34 }).fill).toBe(step(7, surface(34)));
    expect(barFills({ material: "off", backgroundOpacity: 3 }).fill).toBe(step(7, surface(100)));
    expect(barFills({ material: "off", backgroundOpacity: Number.NaN }).fill).toBe(step(7, "transparent"));
    // Transparent: no fill at rest, the hover alone.
    expect(barFills({ material: "transparent", backgroundOpacity: 1 })).toEqual({
      fill: "transparent",
      hover: step(10, "transparent"),
    });
  });

  const secure = { kind: "web", connection: "secure", displayName: "example.com" } as const;

  test("the chip for each presentation", () => {
    expect(chipFor(secure, { kind: "page" }).icon).toBe("browser.omnibox.pageinfo");
    expect(chipFor(secure, { kind: "input", symbol: "globe" }).icon).toBe("browser");
    expect(chipFor(secure, { kind: "input", symbol: "browser.omnibox.search" }).triggerable).toBe(false);
    expect(chipFor(secure, { kind: "keyword", name: "Notes" }).label).toEqual({ keyword: "Notes" });
    expect(chipFor(null, { kind: "engineKeyword", label: "Search YouTube" })).toMatchObject({
      icon: "browser.omnibox.search",
      label: { keyword: "Search YouTube" },
    });
  });

  test("the star hides while editing", () => {
    expect(starFor("on", "editing")).toBe("hidden");
    expect(starFor("on", "focused")).toBe("on");
  });

  test("the resting emphasis is the host", () => {
    const base = { selection: null, rows: [], highlighted: null, hasFocus: false, chip: { kind: "page" } } as const;
    expect(
      emphasisFor({
        ...base,
        text: "example.com/path",
        style: { kind: "compactURL", url: "https://example.com/path" },
      }),
    ).toEqual([0, 11]);
    expect(emphasisFor({ ...base, text: "typed", style: { kind: "plain" } })).toBeNull();
  });

  test("commands go to the host as they are", () => {
    expect(wireCommand({ type: "goBack" })).toEqual({ type: "goBack" });
    expect(wireCommand({ type: "focusAddressBar" })).toBeNull();
  });
});

describe("drafts move with their tab (two panes, two toolbar pages)", () => {
  let revision = 0;
  function hostState(
    tab: string,
    url: string,
    extra: { draft?: OmnibarDraft | null; events?: ToolbarHostState["events"] } = {},
  ): ToolbarHostState {
    revision += 1;
    return {
      revision,
      tab,
      draft: extra.draft ?? null,
      url,
      site: null,
      title: null,
      navigation: { canGoBack: false, canGoForward: false, loading: false },
      showsButtons: true,
      bookmark: "hidden",
      pageInfoOpen: false,
      badges: {},
      extensions: { shows: false, pinned: [] },
      buttons: [],
      omnibar: {
        readOnly: false,
        allowsChromiumSchemes: false,
        home: "",
        showFullURLs: false,
        searchEngine: { id: "google", name: "Google", queryTemplate: "https://www.google.com/search?q={searchTerms}" },
        keywords: [],
        intranetHosts: [],
        fixedTypoHosts: [],
        upward: false,
        searchKeywordFormat: "Search %@",
      },
      look: { material: "off", backgroundOpacity: 1 },
      metrics: {
        bar: 28,
        button: 28,
        fontSize: 13,
        toolbarIcon: 16,
        trailingIcon: 18,
        chipIcon: 16,
        spacing: 3,
        margin: 6,
        inset: 2,
        trailingInset: 2,
        barTop: 4,
        cornerRadius: 8,
        preferredAddress: 200,
        minimumAddress: 100,
        maxPinned: 6,
      },
      events: extra.events ?? [],
    };
  }

  function page() {
    const sent: ToolbarPageCommand[] = [];
    const session = new ToolbarSession((command) => sent.push(command));
    const status = () => sent.filter((command) => command.type === "status").at(-1) as StatusCommand | undefined;
    return { session, sent, status };
  }

  type StatusCommand = Extract<ToolbarPageCommand, { type: "status" }>;
  const event = (seq: number, value: ToolbarHostEvent) => ({ seq, event: value });

  /** Types `text` into pane A's omnibar for tab `tab`, leaving `selection` selected, without submitting. */
  function typeUnsent(
    session: ToolbarSession,
    tab: string,
    url: string,
    text: string,
    selection: [number, number],
    seq = 1,
  ) {
    session.applyHostState(hostState(tab, url, { events: [event(seq, { kind: "focus", source: "programmatic" })] }));
    expect(session.state.phase).not.toBe("idle");
    session.runner.send({
      type: "fieldChanged",
      field: { text, selection: { location: selection[0], length: selection[1] }, marked: null },
      kind: "insert",
    });
  }

  test("the status names its tab and carries the unsent draft", () => {
    const a = page();
    typeUnsent(a.session, "tab-1", "https://one.example/", "weather in paris", [8, 2]);
    expect(a.status()?.tab).toBe("tab-1");
    expect(a.status()?.draft).toEqual({ text: "weather in paris", selection: [8, 2] });
    expect(draftOf(a.session.state)).toEqual({ text: "weather in paris", selection: [8, 2] });
  });

  test("a tab moved to another pane keeps its unsent text and selection", () => {
    const a = page();
    const b = page();
    b.session.applyHostState(hostState("tab-2", "https://two.example/"));
    typeUnsent(a.session, "tab-1", "https://one.example/", "weather in paris", [8, 2]);
    // The host keeps the shown tab's draft as the page reported it (`BrowserChromeTabState.omnibarDraft`).
    const status = a.status();
    const carried = status?.tab === "tab-1" ? status.draft : null;
    // The tab leaves pane A (the host resigns its keys and forgets the slot there) ...
    a.session.applyHostState(
      hostState("tab-3", "https://three.example/", {
        events: [event(2, { kind: "blur" }), event(3, { kind: "forgetTab", tab: "tab-1" })],
      }),
    );
    // ... and pane B shows it with the draft it brought.
    b.session.applyHostState(hostState("tab-1", "https://one.example/", { draft: carried }));
    expect(b.session.state.phase).toBe("idle");
    expect(b.session.state.retainedText).toBe("weather in paris");
    b.session.applyHostState(
      hostState("tab-1", "https://one.example/", {
        draft: carried,
        events: [event(1, { kind: "focus", source: "programmatic" })],
      }),
    );
    expect(b.session.state.phase).toBe("editing");
    expect(b.session.state.edit.userText).toBe("weather in paris");
    expect(b.session.state.edit.selection).toEqual({ location: 8, length: 2 });
    expect(b.status()?.draft).toEqual({ text: "weather in paris", selection: [8, 2] });
    // Pane A forgot the slot: the tab coming back there takes the host's draft, not a stale one.
    a.session.applyHostState(hostState("tab-1", "https://one.example/", { draft: null }));
    expect(a.session.state.retainedText).toBeNull();
  });

  test("a background tab's draft rides the status of the switch that left it", () => {
    const a = page();
    typeUnsent(a.session, "tab-1", "https://one.example/", "draft text", [0, 5]);
    expect(a.status()?.draft).toEqual({ text: "draft text", selection: [0, 5] });
    a.session.applyHostState(hostState("tab-3", "https://three.example/"));
    // The switch posts the leaving tab's resting status before the next tab's.
    const statuses = a.sent.filter((command) => command.type === "status") as StatusCommand[];
    const leaving = statuses.filter((command) => command.tab === "tab-1").at(-1);
    expect(leaving?.draft).toEqual({ text: "draft text", selection: [0, 5] });
    expect(a.status()).toMatchObject({ tab: "tab-3", draft: null });
  });

  test("a submitted or reverted bar carries no draft; a slot of its own wins over the host's", () => {
    const a = page();
    typeUnsent(a.session, "tab-1", "https://one.example/", "one.example/", [12, 0]);
    expect(a.status()?.draft).not.toBeNull();
    a.session.runner.send({ type: "key", key: { kind: "escape" } });
    a.session.runner.send({ type: "key", key: { kind: "escape" } });
    expect(a.status()?.draft).toBeNull();
    typeUnsent(a.session, "tab-1", "https://one.example/", "kept here", [9, 0], 2);
    a.session.applyHostState(hostState("tab-3", "https://three.example/"));
    a.session.applyHostState(
      hostState("tab-1", "https://one.example/", { draft: { text: "older", selection: [0, 0] } }),
    );
    expect(a.session.state.retainedText).toBe("kept here");
  });
  /** Runs `body` with a jsdom document installed (attachInput listens on `document`). */
  function withDocument(body: (document: Document) => void) {
    const scope = globalThis as Record<string, unknown>;
    const had = "document" in scope;
    const saved = scope.document;
    const { window } = new JSDOM('<!doctype html><div class="bc-omnibar"><div class="bc-field"><input></div></div>');
    scope.document = window.document;
    try {
      body(window.document);
    } finally {
      if (had) scope.document = saved;
      else delete scope.document;
      window.close();
    }
  }

  function countFocus(input: HTMLInputElement) {
    const calls = { count: 0 };
    const focus = input.focus.bind(input);
    input.focus = (options?: FocusOptions) => {
      calls.count += 1;
      focus(options);
    };
    return calls;
  }

  test("a focus queued before the input mounts reaches the input when it attaches", () => {
    withDocument((document) => {
      const a = page();
      a.session.applyHostState(
        hostState("tab-1", "https://one.example/", { events: [event(1, { kind: "focus", source: "programmatic" })] }),
      );
      expect(a.session.state.phase).not.toBe("idle");
      const input = document.querySelector("input") as HTMLInputElement;
      const focus = countFocus(input);
      a.session.attachInput(input);
      expect(focus.count).toBe(1);
      expect(document.activeElement).toBe(input);
      const selection = a.session.presentation.selection;
      expect(selection).not.toBeNull();
      expect(input.value).toBe(a.session.presentation.text);
      expect({ start: input.selectionStart, end: input.selectionEnd }).toEqual({
        start: selection!.location,
        end: selection!.location + selection!.length,
      });
    });
  });

  test("an input that attaches with no focus pending stays unfocused", () => {
    withDocument((document) => {
      const a = page();
      a.session.applyHostState(hostState("tab-1", "https://one.example/"));
      const input = document.querySelector("input") as HTMLInputElement;
      const focus = countFocus(input);
      a.session.attachInput(input);
      expect(focus.count).toBe(0);
      expect(document.activeElement).not.toBe(input);
    });
  });
  test("a query of the tab left behind never fills the tab restored (B, A, back to B)", () => {
    const a = page();
    type Effect = Extract<ToolbarPageCommand, { type: "effect" }>["effect"];
    const effects = () => a.sent.flatMap((command) => (command.type === "effect" ? [command.effect] : []));
    const lastQuery = () =>
      effects()
        .filter((effect): effect is Extract<Effect, { type: "query" }> => effect.type === "query")
        .at(-1);
    const row = (url: string) => ({ kind: "navigate" as const, title: url, detail: url, url, score: 900 });
    // Typing in B, then in A: each sends a query.
    typeUnsent(a.session, "tab-b", "https://b.example/", "bee", [3, 0], 1);
    const queryB = lastQuery();
    typeUnsent(a.session, "tab-a", "https://a.example/", "aye", [3, 0], 2);
    const queryA = lastQuery();
    expect(queryA?.generation).not.toBe(queryB?.generation);
    // Leaving A cancels its outstanding query on the host.
    const cancelsBefore = effects().filter((effect) => effect.type === "cancelQuery").length;
    a.session.applyHostState(
      hostState("tab-b", "https://b.example/", { events: [event(3, { kind: "focus", source: "programmatic" })] }),
    );
    expect(effects().filter((effect) => effect.type === "cancelQuery").length).toBeGreaterThan(cancelsBefore);
    expect(a.session.state.phase).toBe("editing");
    expect(a.session.state.edit.userText).toBe("bee");
    // A's delayed result (and B's own, issued before it left) arrive: neither fills B.
    a.session.applyHostState(
      hostState("tab-b", "https://b.example/", {
        events: [
          event(4, { kind: "suggestions", generation: queryA!.generation, rows: [row("https://a-result.example/")] }),
          event(5, { kind: "suggestions", generation: queryB!.generation, rows: [row("https://b-stale.example/")] }),
        ],
      }),
    );
    expect(a.session.state.popup.rows).toEqual([]);
    expect(a.session.state.generation).toBeGreaterThan(Math.max(queryA!.generation, queryB!.generation));
    // Enter navigates to what B typed, never A's result.
    a.session.runner.send({ type: "key", key: { kind: "enter", disposition: "currentTab" } });
    const opened = JSON.stringify(effects().at(-1));
    expect(opened).not.toContain("a-result");
    expect(opened).not.toContain("b-stale");
  });
});
