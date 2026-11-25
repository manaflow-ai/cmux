// Every case of schemas/keymap/key-vectors.json, the vectors cmux-keymap (Rust) runs too, through
// keyStyle.ts: once with the vectors' own events (the key and its shifted character), once as the
// DOM reports the same press (keyEventFromDom: with Shift held only the shifted character). Then
// useListKeys on a list in jsdom.
import { afterEach, describe, expect, jest, test } from "bun:test";
import { act, createElement, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import vectors from "../../../schemas/keymap/key-vectors.json";
import table from "../../../schemas/keymap/key-styles.json";
import {
  LIST_COMMANDS,
  configureKeyStyle,
  createListKeys,
  isEditableTarget,
  keyEventFromDom,
  readKeyStyleSettings,
  strokeMatches,
  type KeyEvent,
  type KeyMod,
  type KeyStyle,
  type ListCommand,
  type ShortcutLayout,
} from "./keyStyle";
import { LIST_KEYS_PENDING_MS, useListKeys } from "./useListKeys";
import { settleReact } from "../../test/support/domTeardown";

type Layouts = Record<string, Record<string, [string, string]>>;
const layouts = vectors.layouts as unknown as Layouts;
type Stroke = { layout?: string; code?: string; mods?: string[]; named?: string };

const NAMED_DOM: Record<string, { code: string; key: string }> = {
  escape: { code: "Escape", key: "Escape" },
  enter: { code: "Enter", key: "Enter" },
  up: { code: "ArrowUp", key: "ArrowUp" },
  down: { code: "ArrowDown", key: "ArrowDown" },
  left: { code: "ArrowLeft", key: "ArrowLeft" },
  right: { code: "ArrowRight", key: "ArrowRight" },
};

/// The vectors' event: {code, key, shiftedKey, mods}.
function vectorEvent(stroke: Stroke): KeyEvent {
  const mods = (stroke.mods ?? []) as KeyMod[];
  if (stroke.named) {
    const named = NAMED_DOM[stroke.named]!;
    return { code: named.code, key: named.key.toLowerCase(), mods };
  }
  const chars = layouts[stroke.layout!]![stroke.code!];
  if (!chars) throw new Error(`no ${stroke.code} in ${stroke.layout}`);
  return { code: stroke.code!, key: chars[0], shiftedKey: chars[1], mods };
}

/// The same press as a DOM KeyboardEvent reports it.
function domInit(stroke: Stroke) {
  const mods = stroke.mods ?? [];
  const shift = mods.includes("shift");
  const base = {
    metaKey: mods.includes("cmd"),
    ctrlKey: mods.includes("ctrl"),
    altKey: mods.includes("alt"),
    shiftKey: shift,
  };
  if (stroke.named) return { ...base, ...NAMED_DOM[stroke.named]! };
  const chars = layouts[stroke.layout!]![stroke.code!]!;
  return { ...base, code: stroke.code!, key: shift ? chars[1] : chars[0] };
}

const domEvent = (stroke: Stroke) => keyEventFromDom(domInit(stroke));

describe("the table", () => {
  test("names the commands this file knows", () => {
    expect([...LIST_COMMANDS]).toEqual([
      "list.next",
      "list.previous",
      "list.first",
      "list.last",
      "list.pageDown",
      "list.pageUp",
      "list.open",
      "list.back",
      "list.search",
      "list.leave",
    ]);
    for (const rows of Object.values(table.styles))
      for (const row of rows) expect(LIST_COMMANDS).toContain(row.command as ListCommand);
  });
});

describe("shortcut vectors", () => {
  for (const vector of vectors.shortcuts) {
    for (const layout of ["followLayout", "qwertyPositions"] as const) {
      const want = vector[layout];
      test(`${vector.name} (${layout}: ${want})`, () => {
        expect(strokeMatches(layout, vector.binding, vectorEvent(vector))).toBe(want);
        expect(strokeMatches(layout, vector.binding, domEvent(vector))).toBe(want);
      });
    }
  }
});

describe("list vectors", () => {
  for (const vector of vectors.lists) {
    const layout = ((vector as { shortcutLayout?: string }).shortcutLayout ?? "followLayout") as ShortcutLayout;
    const inText = (vector as { inText?: boolean }).inText === true;
    for (const [source, build] of [
      ["vector", vectorEvent],
      ["dom", domEvent],
    ] as const) {
      test(`${vector.name} (${source})`, () => {
        const keys = createListKeys(vector.style as KeyStyle, layout);
        const outcomes: string[] = vector.strokes.map((stroke) => keys.feed(build(stroke as Stroke), inText));
        expect(outcomes).toEqual(vector.expect);
      });
    }
  }

  test("reset drops a pending g", () => {
    const keys = createListKeys("vim", "followLayout");
    const g = vectorEvent({ layout: "qwerty", code: "KeyG" });
    expect(keys.feed(g, false)).toBe("pending");
    keys.reset();
    expect(keys.feed(g, false)).toBe("pending");
  });
});

describe("keyEventFromDom", () => {
  test("keeps Dead, lowercases letters and named keys, reads Shift's character", () => {
    expect(
      keyEventFromDom({
        code: "BracketLeft",
        key: "Dead",
        metaKey: true,
        ctrlKey: false,
        altKey: false,
        shiftKey: false,
      }),
    ).toEqual({
      code: "BracketLeft",
      key: "Dead",
      mods: ["cmd"],
    });
    expect(
      keyEventFromDom({ code: "KeyG", key: "G", metaKey: false, ctrlKey: false, altKey: false, shiftKey: true }),
    ).toEqual({
      code: "KeyG",
      key: "g",
      shiftedKey: "G",
      mods: ["shift"],
    });
    expect(
      keyEventFromDom({ code: "Escape", key: "Escape", metaKey: false, ctrlKey: false, altKey: false, shiftKey: false })
        .key,
    ).toBe("escape");
  });
});

describe("settings values", () => {
  test("unknown values keep the defaults", () => {
    expect(readKeyStyleSettings({ "app.keyStyle": "vim", "app.shortcutLayout": "qwertyPositions" })).toEqual({
      keyStyle: "vim",
      shortcutLayout: "qwertyPositions",
    });
    expect(readKeyStyleSettings({ "app.keyStyle": "vi", "app.shortcutLayout": 3 })).toEqual({
      keyStyle: "standard",
      shortcutLayout: "followLayout",
    });
    expect(readKeyStyleSettings(null).keyStyle).toBe("standard");
  });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  configureKeyStyle({});
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

function List(props: { style?: KeyStyle; seen: ListCommand[]; children?: ReactNode }) {
  const onKeyDown = useListKeys({ style: props.style, onCommand: (command) => void props.seen.push(command) });
  return createElement(
    "div",
    { role: "listbox", tabIndex: 0, onKeyDown },
    createElement("input", { className: "search" }),
    createElement("input", { className: "check", type: "checkbox" }),
    createElement("div", { role: "option", className: "row" }, "row"),
  );
}

async function mount(style: KeyStyle | undefined, seen: ListCommand[]) {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(createElement(List, { style, seen })));
  return container;
}

function press(target: Element, init: KeyboardEventInit): KeyboardEvent {
  const event = new dom!.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  act(() => void target.dispatchEvent(event));
  return event;
}

describe("useListKeys", () => {
  test("a command reaches onCommand and is consumed; a pass is left alone", async () => {
    const seen: ListCommand[] = [];
    const container = await mount("vim", seen);
    const row = container.querySelector(".row")!;
    expect(press(row, { code: "KeyJ", key: "j" }).defaultPrevented).toBe(true);
    expect(press(row, { code: "ArrowDown", key: "ArrowDown" }).defaultPrevented).toBe(false);
    expect(press(row, { code: "KeyJ", key: "j", metaKey: true }).defaultPrevented).toBe(false);
    expect(seen).toEqual(["list.next"]);
  });

  test("a search field keeps its typing but leaves with Esc; a checkbox is not a text field", async () => {
    const seen: ListCommand[] = [];
    const container = await mount("vim", seen);
    const search = container.querySelector(".search")!;
    expect(press(search, { code: "KeyJ", key: "j" }).defaultPrevented).toBe(false);
    press(search, { code: "Escape", key: "Escape" });
    press(container.querySelector(".check")!, { code: "KeyK", key: "k" });
    expect(seen).toEqual(["list.leave", "list.previous"]);
  });

  test("gg; a lone Shift keeps the pending g; the g clears after the timeout", async () => {
    const seen: ListCommand[] = [];
    const container = await mount("vim", seen);
    const row = container.querySelector(".row")!;
    press(row, { code: "KeyG", key: "g" });
    press(row, { code: "ShiftLeft", key: "Shift", shiftKey: true });
    press(row, { code: "KeyG", key: "g" });
    expect(seen).toEqual(["list.first"]);
    // The pending g's timeout is the behavior: a fake clock passes it.
    jest.useFakeTimers();
    try {
      press(row, { code: "KeyG", key: "g" });
      jest.advanceTimersByTime(LIST_KEYS_PENDING_MS + 1);
      press(row, { code: "KeyG", key: "g" });
    } finally {
      jest.useRealTimers();
    }
    expect(seen).toEqual(["list.first"]);
  });

  test("follows the host's settings when the surface names no style", async () => {
    const seen: ListCommand[] = [];
    const container = await mount(undefined, seen);
    const row = container.querySelector(".row")!;
    press(row, { code: "KeyN", key: "n", ctrlKey: true });
    expect(seen).toEqual([]);
    act(() => configureKeyStyle({ "app.keyStyle": "emacs" }));
    press(row, { code: "KeyN", key: "n", ctrlKey: true });
    expect(seen).toEqual(["list.next"]);
  });
});

describe("isEditableTarget", () => {
  test("text fields and contenteditable, not buttons or checkboxes", () => {
    const page = new JSDOM(
      '<input id=a><input id=b type=checkbox><textarea id=c></textarea><select id=d></select><div contenteditable="true"><span id=e></span></div><div contenteditable="false" id=f></div><button id=g></button>',
    ).window.document;
    const at = (id: string) => page.getElementById(id);
    expect(["a", "c", "d", "e"].map((id) => isEditableTarget(at(id)))).toEqual([true, true, true, true]);
    expect(["b", "f", "g"].map((id) => isEditableTarget(at(id)))).toEqual([false, false, false]);
    expect(isEditableTarget(null)).toBe(false);
  });
});

describe("Standard", () => {
  test("has no rows, so every key a list sees passes on to the list's own handler", () => {
    expect((table.styles as Record<string, unknown[]>).standard).toEqual([]);
    const keys = createListKeys("standard", "followLayout");
    const presses: KeyEvent[] = [
      { code: "KeyJ", key: "j", mods: [] },
      { code: "KeyK", key: "k", mods: [] },
      { code: "KeyG", key: "g", mods: [] },
      { code: "KeyG", key: "g", shiftedKey: "G", mods: ["shift"] },
      { code: "Slash", key: "/", mods: [] },
      { code: "Escape", key: "escape", mods: [] },
      { code: "KeyN", key: "n", mods: ["ctrl"] },
      { code: "KeyP", key: "p", mods: ["ctrl"] },
      { code: "KeyG", key: "g", mods: ["ctrl"] },
    ];
    for (const inText of [false, true]) {
      for (const press of presses) expect(keys.feed(press, inText)).toBe("pass");
    }
  });
});
