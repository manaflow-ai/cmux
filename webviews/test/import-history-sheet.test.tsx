// Bring your history sheet (#34569): the saved Dot export is one of the aligned source rows (same
// checkbox column and Choose action as the other zip rows), picking it replaces the placeholder with
// the real Dot row, and the footer's Import button carries its keycap as a separate element.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/import-history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { ImportHistory } = await import("../src/pages/import-history/ImportHistory");
const { ImportHistoryStore } = await import("../src/pages/import-history/model");
const { MockImportHistoryProvider } = await import("../src/pages/import-history/mockProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/import-history/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;

async function mount() {
  const store = new ImportHistoryStore(new MockImportHistoryProvider());
  const strings = createStrings(table, ["en"]);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => root!.render(<ImportHistory store={store} strings={strings} />));
  await act(async () => store.start());
  return { store };
}

const sourceRows = () => [...host.querySelectorAll<HTMLElement>(".history-sources > .history-source")];
const titleOf = (row: HTMLElement) => row.querySelector(".history-source-label")?.textContent?.trim();

test("the saved Dot export is an aligned source row with a checkbox and a Choose action", async () => {
  await mount();
  const dot = sourceRows().find((row) => titleOf(row) === "I have a saved Dot export (.zip)");
  expect(dot).toBeDefined();
  expect(dot!.querySelector('.history-source-label input[type="checkbox"]')).not.toBeNull();
  expect(dot!.querySelector(".history-source-action button")?.textContent).toBe("Choose export…");
  // No second, unaligned Dot control outside the list.
  expect(host.querySelectorAll("form > button, .history-content > button").length).toBe(0);
});

test("picking the saved Dot export replaces the placeholder with one checked Dot row", async () => {
  const { store } = await mount();
  await act(async () => store.pickZip("dot"));
  const dots = sourceRows().filter((row) => /^Dot \(|saved Dot/.test(titleOf(row) ?? ""));
  expect(dots.map(titleOf)).toEqual(["Dot (New Computer) export (.zip)"]);
  expect(dots[0]!.querySelector<HTMLInputElement>('input[type="checkbox"]')?.checked).toBe(true);
});

test("the footer sits outside the scrolling list and Import keeps its keycap as its own element", async () => {
  await mount();
  const footer = host.querySelector<HTMLElement>(".history-footer")!;
  expect(footer.closest(".history-scroll")).toBeNull();
  expect(host.querySelector(".history-scroll .history-sources")).not.toBeNull();
  const primary = footer.querySelector<HTMLButtonElement>("button.is-primary")!;
  expect(primary.classList.contains("ui-dialog-button")).toBe(true);
  expect(primary.querySelector("kbd.ui-keyhint")?.textContent).toBe("↩");
  expect(primary.firstChild?.textContent).toBe("Import");
});
