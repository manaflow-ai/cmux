// Ported from OmnibarChromeGapsTests (tab to search, Opt-Cmd-F, Always Show Full URLs, the typed
// http fallback mark) and OmnibarChromeParityTests (Control-Enter), plus extension keyword sessions.
import { describe, expect, test } from "bun:test";
import { presentation } from "./presentation";
import { SEARCH_ENGINES } from "./search-engine";
import { fieldText, initialOmnibarState } from "./state";
import type { OmnibarKeyword } from "./types";
import { commits, engineResolver, enterKey, key, lastGeneration, run, testResolver, typed } from "./testing";
import { urlHostRange } from "./url-display";

describe("tab to search", () => {
  const resolver = engineResolver();
  const go = (inputs: Parameters<typeof run>[1], state = initialOmnibarState()) => run(state, inputs, resolver);

  test("Tab after an engine's site searches that engine", () => {
    const { state: session, effects: started } = go([...typed("youtube.com"), key({ kind: "tab" })]);
    expect(session.keyword?.searchEngine?.id).toBe("youtube");
    expect(session.edit.userText).toBe("");
    expect(started.some((e) => e.type === "keywordStarted")).toBe(false);
    expect(presentation(session).chip).toEqual({ kind: "engineKeyword", label: "Search YouTube" });
    const { effects } = go([...typed("lofi beats", "", false), enterKey], session);
    expect(commits(effects)).toEqual(["https://www.youtube.com/results?search_query=lofi%20beats"]);
  });

  test("an engine keyword and a space start the search", () => {
    const session = go(typed("github.com ")).state;
    expect(session.keyword?.searchEngine?.id).toBe("github");
    const { state, effects } = go([...typed("swift testing", "", false), enterKey], session);
    expect(state.keyword).toBeNull();
    expect(commits(effects)).toEqual(["https://github.com/search?q=swift%20testing"]);
  });

  test("Enter with no text opens the engine's site", () => {
    const { effects } = go([...typed("wikipedia.org"), key({ kind: "tab" }), enterKey]);
    expect(commits(effects)).toEqual(["https://en.wikipedia.org/"]);
  });

  test("Backspace at the start leaves the engine search", () => {
    const { state } = go([...typed("youtube.com"), key({ kind: "tab" }), key({ kind: "backspaceAtStart" })]);
    expect(state.keyword).toBeNull();
    expect(state.edit.userText).toBe("youtube.com");
  });

  test("Search the Web searches with the default engine", () => {
    const session = go([{ type: "focusGained", source: "keyboard" }, key({ kind: "searchWithDefaultEngine" })]).state;
    expect(session.keyword?.searchEngine).toEqual(SEARCH_ENGINES.google);
    expect(presentation(session).chip).toEqual({ kind: "engineKeyword", label: "Search Google" });
    const { effects } = go([...typed("example.com", "", false), enterKey], session);
    expect(commits(effects)).toEqual(["https://www.google.com/search?q=example.com"]);
  });

  test("Search the Web without the engine among the keywords still starts", () => {
    const { state } = run(initialOmnibarState(), [
      { type: "focusGained", source: "keyboard" },
      key({ kind: "searchWithDefaultEngine" }),
    ]);
    expect(state.keyword?.keyword).toBe("google.com");
    expect(state.keywordEntry).toBe("shortcut");
  });
});

describe("Always Show Full URLs", () => {
  test("keeps the scheme and www.", () => {
    const page = "https://www.example.com/a?b=1";
    const compact = initialOmnibarState(page);
    expect(fieldText(compact)).toBe("example.com/a?b=1");
    const full = run(compact, [{ type: "showFullURLsChanged", full: true }]).state;
    expect(fieldText(full)).toBe("https://www.example.com/a?b=1");
    const host = urlHostRange(fieldText(full), page);
    expect(host).not.toBeNull();
    expect(fieldText(full).substr(host!.location, host!.length)).toBe("www.example.com");
    // A focusing click no longer elides: the full URL, all selected.
    const focused = run(full, [{ type: "focusGained", source: "mouse" }]).state;
    expect(focused.elided).toBe(false);
    expect(fieldText(focused)).toBe("https://www.example.com/a?b=1");
  });

  test("a focused elided field shows the full URL when the setting turns on", () => {
    const focused = run(initialOmnibarState("https://www.example.com/a"), [
      { type: "focusGained", source: "mouse" },
    ]).state;
    expect(focused.elided).toBe(true);
    const full = run(focused, [{ type: "showFullURLsChanged", full: true }]).state;
    expect(full.elided).toBe(false);
    expect(full.edit.selection).toEqual({ location: 0, length: "https://www.example.com/a".length });
  });
});

describe("typed http fallback mark", () => {
  test("Enter on a scheme-less address marks its https load as an upgrade", () => {
    const resolver = engineResolver();
    const upgraded = run(initialOmnibarState(), [...typed("example.com"), enterKey], resolver).effects;
    expect(upgraded).toContainEqual({ type: "typedHTTPSUpgrade", url: "https://example.com" });
    const explicit = run(initialOmnibarState(), [...typed("https://example.com"), enterKey], resolver).effects;
    expect(explicit.some((e) => e.type === "typedHTTPSUpgrade")).toBe(false);
  });

  test("a new tab commit is never marked", () => {
    const enterNewTab = key({ kind: "enter", disposition: "newBackgroundTab" });
    const { effects } = run(initialOmnibarState(), [...typed("example.com"), enterNewTab]);
    expect(effects.some((e) => e.type === "typedHTTPSUpgrade")).toBe(false);
    expect(effects).toContainEqual({
      type: "ended",
      reason: { kind: "open", url: "https://example.com", disposition: "newBackgroundTab" },
    });
  });
});

describe("Control-Enter", () => {
  const controlEnter = key({ kind: "enterAddingTLD", disposition: "currentTab" });

  test.each([
    ["example", "https://www.example.com"],
    ["google/maps", "https://www.google.com/maps"],
    ["www.example", "https://www.example.com"],
  ])("%p adds www. and .com", (text, expected) => {
    const { state, effects } = run(initialOmnibarState(), [...typed(text), controlEnter]);
    expect(effects).toContainEqual({ type: "ended", reason: { kind: "commit", url: expected } });
    expect(state.phase).toBe("committing");
  });

  test("a full host loads as typed", () => {
    const { effects } = run(initialOmnibarState(), [...typed("example.org"), controlEnter]);
    expect(effects).toContainEqual({ type: "ended", reason: { kind: "commit", url: "https://example.org" } });
  });
});

describe("extension keyword sessions", () => {
  const ext: OmnibarKeyword = { extensionID: "ext1", keyword: "np", name: "Notes" };
  const resolver = testResolver({ keywords: [ext] });

  test("the keyword and a space start a session the extension hears", () => {
    const { state, effects } = run(initialOmnibarState(), [...typed("np "), ...typed("a", "", false)], resolver);
    expect(state.keyword?.extensionID).toBe("ext1");
    expect(effects).toContainEqual({ type: "keywordStarted", extensionID: "ext1" });
    expect(effects.filter((e) => e.type === "keywordInput").map((e) => e.type === "keywordInput" && e.text)).toEqual([
      "",
      "a",
    ]);
    expect(presentation(state).chip).toEqual({ kind: "keyword", name: "Notes" });
  });

  test("Enter hands the text to the extension", () => {
    const { state, effects } = run(
      initialOmnibarState(),
      [...typed("np "), ...typed("todo", "", false), enterKey],
      resolver,
    );
    expect(state.phase).toBe("committing");
    expect(effects).toContainEqual({
      type: "ended",
      reason: { kind: "keyword", extensionID: "ext1", text: "todo", disposition: "currentTab" },
    });
  });

  test("blur ends the session and drops its text", () => {
    const { state, effects } = run(
      initialOmnibarState(),
      [...typed("np "), ...typed("x", "", false), { type: "focusLost" }],
      resolver,
    );
    expect(state.keyword).toBeNull();
    expect(state.retainedText).toBeNull();
    expect(effects).toContainEqual({ type: "keywordEnded", extensionID: "ext1" });
  });

  test("the extension's rows come back as suggestions; a click commits the row's content", () => {
    const session = run(initialOmnibarState(), [...typed("np "), ...typed("t", "", false)], resolver);
    const rows = [
      {
        kind: "keyword" as const,
        title: "Todo",
        detail: "",
        url: "cmux-omnibox://ext1/todo",
        score: 1000,
        content: "todo",
      },
    ];
    const generation = lastGeneration(session.effects);
    const { effects } = run(
      session.state,
      [
        { type: "suggestions", generation, rows },
        { type: "rowClick", row: 0, disposition: "currentTab" },
      ],
      resolver,
    );
    expect(effects).toContainEqual({
      type: "ended",
      reason: { kind: "keyword", extensionID: "ext1", text: "todo", disposition: "currentTab" },
    });
  });
});
