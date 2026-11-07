// The suggestion card, inline completion, Escape, undo and the commit paths of the reducer.
import { describe, expect, test } from "bun:test";
import { copyContent } from "./copy";
import { HostTypoMemory } from "./host-typo-fixup";
import { presentation } from "./presentation";
import { reduce } from "./reducer";
import { fieldText, initialOmnibarState } from "./state";
import type { OmnibarState } from "./state";
import type { BrowserSuggestion } from "./types";
import { commits, enterKey, key, lastGeneration, row, run, selection, testResolver, typed } from "./testing";

/** Types `text` and answers its last query with `rows`. */
function withRows(text: string, rows: BrowserSuggestion[], state = initialOmnibarState()): OmnibarState {
  const typedState = run(state, typed(text));
  return run(typedState.state, [{ type: "suggestions", generation: lastGeneration(typedState.effects), rows }]).state;
}

const github = row("history", "https://github.com/", { title: "GitHub" });
const search = row("search", "https://www.google.com/search?q=git", { title: "git" });

describe("inline completion", () => {
  test("a history row completes the typed text and becomes the default row", () => {
    const state = withRows("git", [search, github]);
    expect(fieldText(state)).toBe("github.com");
    expect(state.edit.inlineCompletion).toBe("hub.com");
    expect(state.edit.selection).toEqual({ location: 3, length: 7 });
    expect(state.popup.rows[0]).toBe(github);
  });

  test("typing the next character keeps the rest until fresh rows arrive", () => {
    const state = run(withRows("git", [search, github]), typed("h", "git", false)).state;
    expect(state.edit.inlineCompletion).toBe("ub.com");
    expect(state.popup.stale).toBe(true);
  });

  test("a deletion suppresses the completion", () => {
    const deleted = run(withRows("gith", [github]), [
      { type: "fieldChanged", field: { text: "git", selection: { location: 3, length: 0 } }, kind: "delete" },
    ]);
    const state = run(deleted.state, [
      { type: "suggestions", generation: lastGeneration(deleted.effects), rows: [github] },
    ]).state;
    expect(state.edit.inlineCompletion).toBe("");
  });

  test("rows not marked completable never complete", () => {
    const state = withRows("git", [{ ...github, inlineCompletable: false }]);
    expect(state.edit.inlineCompletion).toBe("");
    expect(fieldText(state)).toBe("git");
  });

  test("Enter on the completion is a typed navigation", () => {
    const { effects } = run(withRows("git", [github]), [enterKey]);
    expect(effects).toContainEqual({ type: "typedNavigation", url: "https://github.com/" });
    expect(commits(effects)).toEqual(["https://github.com/"]);
  });

  test("a stale result generation is ignored", () => {
    const typedState = run(initialOmnibarState(), typed("git"));
    const stale = lastGeneration(typedState.effects) - 1;
    const state = run(typedState.state, [{ type: "suggestions", generation: stale, rows: [github] }]).state;
    expect(state.popup.rows).toEqual([]);
  });
});

/** Rows that never complete inline, so the field keeps the typed text. */
const plain = (r: BrowserSuggestion): BrowserSuggestion => ({ ...r, inlineCompletable: false });

describe("arrowing", () => {
  const rows = [plain(row("navigate", "https://git.com")), plain(github), search];

  test("Down shows the row's text; Escape goes back to the typed text, then closes, then reverts", () => {
    const page = initialOmnibarState("https://example.com/");
    const open = withRows("git", rows, page);
    const down = run(open, [key({ kind: "down" })]).state;
    expect(down.popup.selected).toBe(1);
    expect(fieldText(down)).toBe("https://github.com/");
    const back = run(down, [key({ kind: "escape" })]).state;
    expect(back.popup.selected).toBe(0);
    expect(fieldText(back)).toBe("git");
    const closed = run(back, [key({ kind: "escape" })]);
    expect(closed.state.popup.rows).toEqual([]);
    expect(closed.effects).toContainEqual({ type: "cancelQuery" });
    const reverted = run(closed.state, [key({ kind: "escape" })]).state;
    expect(reverted.phase).toBe("focused");
    expect(fieldText(reverted)).toBe("example.com");
    const ended = run(reverted, [key({ kind: "escape" })]);
    expect(ended.state.phase).toBe("idle");
    expect(ended.effects).toContainEqual({ type: "ended", reason: { kind: "cancel" } });
  });

  test("Up and Down clamp; Tab past the end is not handled", () => {
    const open = withRows("git", rows);
    expect(run(open, [key({ kind: "up" })]).state.popup.selected).toBe(0);
    const last = run(open, [key({ kind: "down" }), key({ kind: "down" }), key({ kind: "down" })]).state;
    expect(last.popup.selected).toBe(2);
    expect(reduce(last, { type: "key", key: { kind: "tab" } }, testResolver()).handled).toBe(false);
  });

  test("Enter on an arrowed row loads the row", () => {
    const { effects } = run(withRows("git", rows), [key({ kind: "down" }), key({ kind: "down" }), enterKey]);
    expect(commits(effects)).toEqual(["https://www.google.com/search?q=git"]);
    expect(effects.some((e) => e.type === "typedNavigation")).toBe(false);
  });

  test("fresh rows keep the arrowed row", () => {
    const down = run(withRows("git", rows), [key({ kind: "down" })]).state;
    const fresh = [search, row("history", "https://gitlab.com/"), plain(github)];
    const state = run(down, [{ type: "suggestions", generation: down.generation, rows: fresh }]).state;
    expect(state.popup.selected).toBe(2);
    expect(state.popup.rows).toEqual(fresh);
  });

  test("Shift-Delete removes a history row and asks to forget it", () => {
    const down = run(withRows("git", rows), [key({ kind: "down" })]).state;
    const { state, effects } = run(down, [key({ kind: "deleteSuggestion" })]);
    expect(effects).toContainEqual({ type: "deleteSuggestion", url: "https://github.com/" });
    expect(state.popup.rows.map((r) => r.url)).toEqual(["https://git.com", search.url]);
  });
});

describe("rows and the mouse", () => {
  const rows = [plain(row("navigate", "https://git.com")), plain(github)];

  test("hover highlights only after the pointer moved", () => {
    const open = withRows("git", rows);
    const first = run(open, [{ type: "rowHover", row: 1, pointer: { x: 5, y: 5 } }]).state;
    expect(presentation(first).highlighted).toBe(0);
    const moved = run(first, [{ type: "rowHover", row: 1, pointer: { x: 6, y: 5 } }]).state;
    expect(presentation(moved).highlighted).toBe(1);
  });

  test("a Switch to Tab row reveals the tab", () => {
    const tab = row("switchToTab", "https://github.com/", { tabKey: "tab_1" });
    const { state, effects } = run(withRows("git", [rows[0], tab]), [
      { type: "rowClick", row: 1, disposition: "currentTab" },
    ]);
    expect(state.phase).toBe("idle");
    expect(effects).toContainEqual({ type: "ended", reason: { kind: "switchToTab", key: "tab_1" } });
  });

  test("a click opens the row the card drew, even when newer rows arrived in the same push", () => {
    const first = plain(row("history", "https://first.example/"));
    const second = plain(row("history", "https://second.example/"));
    const open = withRows("ex", [first]);
    const pending = run(open, typed("a", "ex", false));
    const shown = { kind: first.kind, url: first.url };
    // The newer query's rows land first; the click names the row it was on.
    const moved = run(pending.state, [
      { type: "suggestions", generation: lastGeneration(pending.effects), rows: [second, first] },
      { type: "rowClick", row: 0, disposition: "currentTab", shown },
    ]);
    expect(commits(moved.effects)).toEqual(["https://first.example/"]);
    // Rows that no longer hold it take no click at all.
    const gone = run(pending.state, [
      { type: "suggestions", generation: lastGeneration(pending.effects), rows: [second] },
      { type: "rowClick", row: 0, disposition: "currentTab", shown },
    ]);
    expect(commits(gone.effects)).toEqual([]);
    expect(gone.handled).toBe(false);
  });

  test("an answer row copies its content", () => {
    const answer = row("answer", "cmux-answer://4", { title: "2+2 = 4", content: "4" });
    const { state, effects } = run(withRows("2+2", [answer]), [enterKey]);
    expect(effects).toContainEqual({ type: "copyAnswer", text: "4" });
    expect(state.phase).toBe("editing");
  });

  test("late rows fill the card below the highlight", () => {
    const open = withRows("git", rows);
    const late = row("search", "https://www.google.com/search?q=gitx", { title: "gitx", score: 5 });
    const state = run(open, [
      { type: "moreSuggestions", generation: open.generation, rows: [late, github], capacity: 8 },
    ]).state;
    expect(state.popup.rows.map((r) => r.url)).toEqual(["https://git.com", github.url, late.url]);
    expect(state.popup.selected).toBe(0);
  });
});

describe("undo, paste and page changes", () => {
  test("undo brings back the untouched URL, redo the typed text", () => {
    const page = initialOmnibarState("https://example.com/a");
    const edited = run(page, typed("ab")).state;
    const undone = run(edited, [key({ kind: "undo" })]).state;
    expect(undone.phase).toBe("focused");
    expect(fieldText(undone)).toBe("https://example.com/a");
    const redone = run(undone, [key({ kind: "redo" })]).state;
    expect(fieldText(redone)).toBe("ab");
  });

  test("a page URL change replaces untouched text but never typed text", () => {
    const focused = run(initialOmnibarState("https://a.com/"), [{ type: "focusGained", source: "keyboard" }]).state;
    expect(fieldText(run(focused, [{ type: "pageURLChanged", url: "https://b.com/" }]).state)).toBe("b.com");
    const editing = run(focused, typed("x", "", false)).state;
    expect(fieldText(run(editing, [{ type: "pageURLChanged", url: "https://b.com/" }]).state)).toBe("x");
  });

  test("pasted text loads as it is, with no typo fix", () => {
    const pasted = run(initialOmnibarState(), [
      { type: "focusGained", source: "keyboard" },
      { type: "fieldChanged", field: { text: "example.con", selection: { location: 11, length: 0 } }, kind: "paste" },
      enterKey,
    ]);
    expect(commits(pasted.effects)).toEqual(["https://example.con"]);
  });

  test("typed text gets its typo fixed once", () => {
    const memory = new HostTypoMemory();
    const resolver = testResolver({ memory });
    const { effects } = run(initialOmnibarState(), [...typed("example.con"), enterKey], resolver);
    expect(effects).toContainEqual({ type: "hostTypoFixed", typedHost: "example.con" });
    expect(commits(effects)).toEqual(["https://example.com"]);
    memory.recordFix("example.con");
    expect(commits(run(initialOmnibarState(), [...typed("example.con"), enterKey], resolver).effects)).toEqual([
      "https://example.con",
    ]);
  });

  test("Paste and Go loads the pasted text; nothing resolvable beeps", () => {
    const { effects } = run(initialOmnibarState(), [{ type: "pasteAndGo", text: "example.org\n" }]);
    expect(commits(effects)).toEqual(["https://example.org"]);
    expect(run(initialOmnibarState(), [{ type: "pasteAndGo", text: "  " }]).effects).toEqual([{ type: "beep" }]);
  });

  test("blur keeps typed text; the next navigation drops it", () => {
    const blurred = run(initialOmnibarState("https://a.com/"), [...typed("half"), { type: "focusLost" }]);
    expect(blurred.effects).toContainEqual({ type: "ended", reason: { kind: "blur" } });
    expect(fieldText(blurred.state)).toBe("half");
    expect(presentation(blurred.state).style).toEqual({ kind: "plain" });
    const navigated = run(blurred.state, [{ type: "pageURLChanged", url: "https://b.com/" }]).state;
    expect(fieldText(navigated)).toBe("b.com");
  });
});

describe("elision and copy", () => {
  const page = "https://www.example.com/path";

  test("a caret move unelides into the full URL", () => {
    const focused = run(initialOmnibarState(page), [{ type: "focusGained", source: "programmatic" }]).state;
    expect(fieldText(focused)).toBe("example.com/path");
    const moved = run(focused, [selection("example.com/path", 4)]).state;
    expect(moved.elided).toBe(false);
    expect(moved.edit.selection).toEqual({ location: 16, length: 0 });
  });

  test("Home unelides even from select-all", () => {
    const focused = run(initialOmnibarState(page), [{ type: "focusGained", source: "programmatic" }]).state;
    const home = run(focused, [key({ kind: "home", extend: false })]).state;
    expect(fieldText(home)).toBe(page);
    expect(home.edit.selection).toEqual({ location: 0, length: 0 });
  });

  test("copying the whole untouched URL copies the page URL", () => {
    const focused = run(initialOmnibarState(page), [{ type: "focusGained", source: "programmatic" }]).state;
    expect(copyContent(focused, testResolver())).toEqual({ text: page, url: page });
  });

  test("a typed same-host address gets the page's scheme", () => {
    const edited = run(initialOmnibarState("http://example.com/"), [
      ...typed("example.com/x"),
      key({ kind: "selectAll" }),
    ]).state;
    expect(copyContent(edited, testResolver())).toEqual({ text: "http://example.com/x", url: "http://example.com/x" });
  });
});
