// `app.keyStyle` in the palette menu (PaletteMenu.tsx): in the search field Vim's Esc gives the
// keyboard to the list, where j/k, gg/G and l move and pick and / goes back; Emacs' Ctrl-N/P move
// from the field. Standard is today's menu: Esc in the field closes it.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PaletteMenu } from "./PaletteMenu";
import { settleReact } from "../../../test/support/domTeardown";
import { pressStyleKeys, type StyleKey } from "../../../test/support/keyStylePress";
import { configureKeyStyle } from "../../ui/keyStyle";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
});
afterEach(async () => {
  configureKeyStyle({});
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

async function drive(style: string, keys: StyleKey[]) {
  const picks: string[] = [];
  act(() => configureKeyStyle({ "app.keyStyle": style }));
  await act(async () =>
    root!.render(
      <PaletteMenu
        label="Add"
        button="+"
        sections={[
          {
            title: "Tools",
            choices: ["alpha", "beta", "gamma", "delta"].map((id) => ({ id, name: id })),
            onPick: (id: string) => void picks.push(id),
          },
        ]}
      />,
    ),
  );
  const trigger = container.querySelector<HTMLButtonElement>(".acpmux-picker-button")!;
  await act(async () => trigger.click());
  const doc = dom!.window.document;
  container.querySelector<HTMLInputElement>("input[role=combobox]")!.focus();
  for (const key of keys)
    pressStyleKeys(dom!.window, doc.activeElement ?? doc.body, [key], (dispatch) => act(dispatch));
  return {
    open: trigger.getAttribute("aria-expanded") === "true",
    active: container.querySelector('[role="option"][aria-selected="true"]')?.getAttribute("data-value"),
    focus: doc.activeElement?.getAttribute("role"),
    picks,
  };
}

test.each([
  ["vim", ["j"], "alpha", "combobox"],
  ["vim", ["Escape"], "alpha", "listbox"],
  ["vim", ["Escape", "j", "j"], "gamma", "listbox"],
  ["vim", ["Escape", "G", "k"], "gamma", "listbox"],
  ["vim", ["Escape", "G", "g", "g"], "alpha", "listbox"],
  ["vim", ["Escape", "j", "/"], "beta", "combobox"],
  ["emacs", ["C-n", "C-n"], "gamma", "combobox"],
  ["emacs", ["C-n", "C-p"], "alpha", "combobox"],
] as [string, StyleKey[], string, string][])(
  "%s %j: %s active, the %s has the keyboard",
  async (style, keys, active, focus) => {
    expect(await drive(style, keys)).toMatchObject({ open: true, active, focus });
  },
);

test("Vim: l in the list picks the active row and Esc there closes the menu", async () => {
  expect((await drive("vim", ["Escape", "j", "l"])).picks).toEqual(["beta"]);
  act(() => root!.unmount());
  root = createRoot(container);
  expect(await drive("vim", ["Escape", "Escape"])).toMatchObject({ open: false, picks: [] });
});

test("Standard: j types and Esc in the field closes the menu, as before", async () => {
  expect(await drive("standard", ["j"])).toMatchObject({ open: true, active: "alpha", focus: "combobox" });
  act(() => root!.unmount());
  root = createRoot(container);
  expect(await drive("standard", ["Escape"])).toMatchObject({ open: false });
});
