// The reasoning menu draws as a native menu: every row is one line, the check sits in a leading
// gutter that every row keeps (so labels align whether or not a row is checked), and Ultracode's
// note (its On row, ComposerPickers.tsx) is one short phrase beside the row's name in every
// language, not a wrapped second line.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { EffortPicker } from "./EffortPicker";
import { reasoningChoices } from "./ComposerPickers";
import { STRING_TABLES, translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const claudeLevels = ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value }));
const opus = { efforts: ["low", "medium", "high", "xhigh", "max"] };

async function openMenu(container: HTMLElement) {
  const efforts = reasoningChoices(claudeLevels, opus, (key) => translate(key));
  await act(async () => {
    root = createRoot(container);
    root.render(
      <EffortPicker
        label="effort"
        efforts={efforts}
        current="medium"
        onPick={() => {}}
        ultracode={{
          title: translate("effort.level.ultracode"),
          choices: [
            { id: "on", name: translate("picker.on"), description: translate("effort.ultracodeDetail") },
            { id: "off", name: translate("picker.off") },
          ],
          current: "off",
          on: "on",
          onPick() {},
        }}
        speed={{
          title: "Fast Mode",
          choices: [
            { id: "on", name: "On" },
            { id: "off", name: "Off" },
          ],
          current: "on",
          on: "on",
          onPick() {},
        }}
      />,
    );
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='effort']")!.click());
  await settle();
  return [...document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
}

test("every row, checked or not, starts with the same check gutter before its label", async () => {
  const rows = await openMenu(installDom());
  expect(rows.length).toBe(9);
  for (const row of rows) {
    const first = row.firstElementChild!;
    expect(first.classList.contains("ui-menu-check")).toBe(true);
    expect(first.nextElementSibling?.classList.contains("acpmux-effort-text")).toBe(true);
    // Nothing else in the row (no trailing check) takes a column of its own.
    expect(row.children.length).toBe(2);
  }
  const checked = rows.filter((row) => row.getAttribute("aria-checked") === "true");
  expect(checked.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "Medium",
    translate("picker.off"),
    "On",
  ]);
  for (const row of checked) expect(row.querySelector(".ui-menu-check")?.textContent).toBe("✓");
});

test("Ultracode's note sits on its own row's line, with the full text as its tooltip", async () => {
  const rows = await openMenu(installDom());
  // Ultracode's On row (the section after the levels) carries the note.
  const ultracode = rows.find((row) => row.querySelector(".acpmux-effort-detail"))!;
  expect(ultracode.querySelector(".acpmux-menu-label")?.textContent).toBe(translate("picker.on"));
  const detail = ultracode.querySelector<HTMLElement>(".acpmux-effort-text > .acpmux-effort-detail")!;
  expect(detail.textContent).toBe(translate("effort.ultracodeDetail"));
  expect(detail.title).toBe(detail.textContent!);
  // Only Ultracode's On row carries a note; every other row stays a bare label.
  expect(document.querySelectorAll(".acpmux-effort-detail").length).toBe(1);
});

test("Ultracode's note is one short phrase in every language", () => {
  const locales = Object.entries(STRING_TABLES);
  expect(locales.length).toBeGreaterThan(10);
  for (const [locale, table] of locales) {
    const note = table["effort.ultracodeDetail"];
    expect({ locale, defined: typeof note === "string" && note.length > 0 }).toEqual({ locale, defined: true });
    expect({ locale, oneLine: !/\n/.test(note!) }).toEqual({ locale, oneLine: true });
    // Short enough to sit beside "Ultracode" inside the menu's 280 px without a second line.
    const graphemes = [...new Intl.Segmenter(locale).segment(note!)].length;
    expect({ locale, short: graphemes <= 32 }).toEqual({ locale, short: true });
  }
});
