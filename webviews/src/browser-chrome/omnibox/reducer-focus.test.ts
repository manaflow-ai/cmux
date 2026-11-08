// Ported from OmnibarFocusParityTests, OmnibarFocusClickSelectionTests, OmnibarFocusClickChipTests
// and OmnibarDropTests (the reducer cases; the AppKit bar cases stay with the Swift view).
import { describe, expect, test } from "bun:test";
import { presentation } from "./presentation";
import { fieldText, hasFocus, initialOmnibarState } from "./state";
import type { OmnibarInput } from "./types";
import { engineResolver, key, run, selection, typed } from "./testing";

const mouseDown: OmnibarInput = { type: "fieldMouseDown", clickCount: 1 };
const mouseUp: OmnibarInput = { type: "fieldMouseUp" };
const focus = (source: "mouse" | "keyboard" | "programmatic"): OmnibarInput => ({ type: "focusGained", source });

describe("focus parity (OmnibarFocusParityTests)", () => {
  const resolver = engineResolver();
  const go = (inputs: OmnibarInput[], state = initialOmnibarState()) => run(state, inputs, resolver);

  test("Cmd-L leaves keyword mode and selects all", () => {
    const session = go([...typed("youtube.com"), key({ kind: "tab" }), ...typed("lofi", "", false)]).state;
    expect(session.keyword?.searchEngine?.id).toBe("youtube");
    const { state } = go([key({ kind: "focusLocation" })], session);
    expect(state.keyword).toBeNull();
    expect(fieldText(state)).toBe("youtube.com lofi");
    expect(state.edit.selection).toEqual({ location: 0, length: "youtube.com lofi".length });
    expect(presentation(state).chip).not.toEqual({ kind: "engineKeyword", label: "Search YouTube" });
  });

  test("Backspace right after Tab gives the keyword back", () => {
    const { state } = go([...typed("youtube.com"), key({ kind: "tab" }), key({ kind: "backspaceAtStart" })]);
    expect(state.keyword).toBeNull();
    expect(state.edit.userText).toBe("youtube.com");
    expect(state.edit.selection).toEqual({ location: 11, length: 0 });
  });

  test("Backspace after typing keeps a space after the keyword", () => {
    const session = go([...typed("youtube.com"), key({ kind: "tab" }), ...typed("lofi", "", false)]).state;
    const { state } = go([selection("lofi", 0), key({ kind: "backspaceAtStart" })], session);
    expect(state.keyword).toBeNull();
    expect(state.edit.userText).toBe("youtube.com lofi");
    expect(state.edit.selection).toEqual({ location: 12, length: 0 });
  });

  test("Backspace after a space entry keeps the space", () => {
    const { state } = go([...typed("github.com "), key({ kind: "backspaceAtStart" })]);
    expect(state.keyword).toBeNull();
    expect(state.edit.userText).toBe("github.com ");
    expect(state.edit.selection).toEqual({ location: 11, length: 0 });
  });

  test("Backspace after Search the Web restores no keyword", () => {
    const session = go([
      focus("keyboard"),
      key({ kind: "searchWithDefaultEngine" }),
      ...typed("cats", "", false),
    ]).state;
    const { state } = go([selection("cats", 0), key({ kind: "backspaceAtStart" })], session);
    expect(state.keyword).toBeNull();
    expect(state.edit.userText).toBe("cats");
    expect(state.edit.selection).toEqual({ location: 0, length: 0 });
  });

  test("a focus that is not a click or Cmd-L restores the saved selection", () => {
    const moved = go([...typed("goo"), selection("goo", 1)]).state;
    const back = go([{ type: "focusLost" }, focus("programmatic")], moved).state;
    expect(fieldText(back)).toBe("goo");
    expect(back.edit.selection).toEqual({ location: 1, length: 0 });
  });

  test("Cmd-L selects all over the saved selection", () => {
    const back = go([...typed("goo"), { type: "focusLost" }, focus("keyboard")]).state;
    expect(back.edit.selection).toEqual({ location: 0, length: 3 });
  });

  test("a focusing click selects all over the saved selection", () => {
    const back = go([...typed("goo"), { type: "focusLost" }, mouseDown, focus("mouse"), mouseUp]).state;
    expect(back.edit.selection).toEqual({ location: 0, length: 3 });
  });

  test("an untouched URL comes back all selected", () => {
    const page = initialOmnibarState("https://example.com/a");
    const back = go([focus("programmatic"), { type: "focusLost" }, focus("programmatic")], page).state;
    expect(back.edit.selection).toEqual({ location: 0, length: fieldText(back).length });
  });
});

describe("the focusing click selects all (OmnibarFocusClickSelectionTests)", () => {
  const page = () => initialOmnibarState("http://127.0.0.1:49216/omnibar/selection-probe?q=highlight");

  test("a still click the field turned into a selection selects all", () => {
    const focused = run(page(), [mouseDown, focus("mouse")]).state;
    const shifted = run(focused, [selection(fieldText(focused), 5, 8), mouseUp]).state;
    expect(shifted.edit.selection).toEqual({ location: 0, length: fieldText(shifted).length });
  });

  test("a still click that left a caret selects all", () => {
    const focused = run(page(), [mouseDown, focus("mouse")]).state;
    const clicked = run(focused, [selection(fieldText(focused), 5), mouseUp]).state;
    expect(clicked.edit.selection).toEqual({ location: 0, length: fieldText(clicked).length });
  });

  test("a focusing drag keeps what it selected", () => {
    const focused = run(page(), [mouseDown, focus("mouse")]).state;
    const dragged = run(focused, [{ type: "fieldMouseDragged" }, selection(fieldText(focused), 5, 8), mouseUp]).state;
    expect(dragged.edit.selection).toEqual({ location: 5, length: 8 });
  });
});

describe("the chip keeps its label through focus (OmnibarFocusClickChipTests)", () => {
  test("through the focusing click", () => {
    const rest = initialOmnibarState("http://example.com/a");
    expect(presentation(rest).chip).toEqual({ kind: "page" });
    const pressed = run(rest, [mouseDown, focus("mouse")]).state;
    expect(hasFocus(pressed)).toBe(true);
    expect(presentation(pressed).chip).toEqual({ kind: "page" });
    expect(presentation(run(pressed, [mouseUp]).state).chip).toEqual({ kind: "page" });
  });

  test("keyboard focus keeps the label until typing", () => {
    const focused = run(initialOmnibarState("http://example.com/a"), [focus("keyboard")]).state;
    expect(presentation(focused).chip).toEqual({ kind: "page" });
    const typedState = run(focused, [
      { type: "fieldChanged", field: { text: "s", selection: { location: 1, length: 0 } }, kind: "insert" },
    ]).state;
    expect(presentation(typedState).chip.kind).toBe("input");
  });
});

describe("drops (OmnibarDropTests)", () => {
  test("a drop replaces the text, all selected, and loads nothing", () => {
    const page = initialOmnibarState("https://example.com/a");
    const { state, effects } = run(page, [
      focus("programmatic"),
      { type: "dropped", text: "https://swift.org/documentation/" },
    ]);
    expect(state.phase).toBe("editing");
    expect(fieldText(state)).toBe("https://swift.org/documentation/");
    expect(state.edit.selection).toEqual({ location: 0, length: 32 });
    expect(state.edit.inlineCompletion).toBe("");
    expect(effects.some((e) => e.type === "ended")).toBe(false);
    expect(effects.some((e) => e.type === "query")).toBe(true);
  });

  test.each([
    ["javascript:alert(1)", "alert(1)"],
    ["JavaScript: javascript:void(0)", "void(0)"],
    ["  two\n words  \t here ", "two words here"],
  ])("dropped text %p is cleaned", (dropped, expected) => {
    const { state } = run(initialOmnibarState(), [focus("programmatic"), { type: "dropped", text: dropped }]);
    expect(fieldText(state)).toBe(expected);
  });

  test("a drop with nothing to show is not handled", () => {
    const { state, handled } = run(initialOmnibarState(), [focus("programmatic"), { type: "dropped", text: "  \n " }]);
    expect(handled).toBe(false);
    expect(state.phase).toBe("focused");
  });
});
