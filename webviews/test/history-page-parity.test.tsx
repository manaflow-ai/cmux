// History H4 parity (plans/cmux-next/react-pages.md 2.1 and 4, cx-gzh.16): every feature of the
// History page the Swift page had, driven through the page with the mock provider, plus the
// checklist rules both pages share (Japanese strings, one background, Reduce Motion).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const menu of dom.window.document.querySelectorAll('[role="menu"]')) menu.remove();
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { HistoryPage } = await import("../src/pages/history/HistoryPage");
const { UiProvider, languageDirection } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/history/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockHistoryProvider } = await import("../src/pages/history/mockProvider");
const { HistoryStore } = await import("../src/pages/history/store");
const { HistoryOps, ACTION_RUN } = await import("../src/pages/history/types");

/** The mock daemon, recording every call the page makes. */
class RecordingProvider extends MockHistoryProvider {
  calls: Array<{ op: string; params: Record<string, unknown> }> = [];
  override async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params: (params ?? {}) as Record<string, unknown> });
    return super.call<R>(op, params);
  }
  last(op: string): Record<string, unknown> | undefined {
    return this.calls.filter((call) => call.op === op).at(-1)?.params;
  }
}

async function mount(languages: string[] = ["en"], provider = new RecordingProvider()) {
  const store = new HistoryStore(provider, { newKey: () => "k" });
  const strings = createStrings(table, languages);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <HistoryPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  return { provider, store };
}

const rows = () => [...host.querySelectorAll<HTMLElement>(".history-row")];
const button = (text: string) =>
  [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!;
const menuItem = (text: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) => item.textContent === text);
const menuLabels = () =>
  [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((item) => item.textContent);

async function click(element: HTMLElement) {
  await act(async () => element.click());
}

async function key(element: HTMLElement, name: string) {
  await act(async () => {
    element.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });
}

async function contextMenu(row: HTMLElement) {
  await act(async () => {
    row.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    );
  });
}

async function type(text: string) {
  const search = host.querySelector<HTMLInputElement>(".history-search")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(search, text);
    search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {});
}

test("the page opens with search focused and asks for at most 1000 entries", async () => {
  const { provider } = await mount();
  expect(dom.window.document.activeElement?.className).toBe("history-search");
  expect(provider.last(HistoryOps.list)?.limit).toBe(1000);
  expect(rows().length).toBeGreaterThan(0);
});

test("the chips are All, Pages, Locations, Commands, Agents and Closed, and each narrows the list by kind", async () => {
  const { provider } = await mount();
  const chips = [...host.querySelectorAll<HTMLElement>('[role="tab"]')].map((chip) => chip.textContent);
  expect(chips).toEqual(["All", "Pages", "Locations", "Commands", "Agents", "Closed"]);
  for (const [chip, kind] of [
    ["Pages", "page"],
    ["Locations", "location"],
    ["Commands", "command"],
    ["Agents", "agent"],
    ["Closed", "closed"],
  ] as const) {
    await click(button(chip));
    expect(provider.last(HistoryOps.list)?.kinds).toEqual([kind]);
    expect(button(chip).getAttribute("aria-selected")).toBe("true");
  }
  await click(button("All"));
  expect(provider.last(HistoryOps.list)?.kinds).toEqual([]);
});

test("search sends the typed text, and a search with no match says No matches", async () => {
  const { provider } = await mount();
  await type("zz-no-such-entry");
  expect(provider.last(HistoryOps.list)?.text).toBe("zz-no-such-entry");
  expect(host.querySelector(".history-empty")?.textContent).toBe(table.en!["page.emptySearch"]);
});

test("an empty history says No history", async () => {
  await mount(["en"], new RecordingProvider([]));
  expect(rows().length).toBe(0);
  expect(host.querySelector(".history-empty")?.textContent).toBe(table.en!["page.empty"]);
});

test("Group By offers Day, Workspace and Machine; by machine, local entries group under This Mac", async () => {
  await mount();
  await click(button("Group By"));
  expect(menuLabels()).toEqual(["Day", "Workspace", "Machine"]);
  await click(menuItem("Machine")!);
  const titles = [...host.querySelectorAll(".history-group-title")].map((title) => title.textContent);
  expect(titles).toContain(table.en!["group.thisMac"]);
  expect(titles.length).toBeGreaterThan(1);
});

test("Up and Down move the selection, and Return opens the selected row in the app", async () => {
  const { provider } = await mount();
  const list = host.querySelector<HTMLElement>("#history-list")!;
  await key(list, "ArrowDown");
  await key(list, "ArrowDown");
  const selected = host.querySelector<HTMLElement>('.history-row[aria-selected="true"]')!;
  expect(selected).toBe(rows()[1]);
  await key(list, "Enter");
  const run = provider.last(ACTION_RUN)!;
  expect(run.action).toBe("history.open");
  expect((run.args as { new_tab: boolean }).new_tab).toBe(false);
});

test("an offline machine's entries are greyed, badged Offline and cannot be opened", async () => {
  const { provider } = await mount();
  const offline = rows().filter((row) => row.classList.contains("unavailable"));
  expect(offline.length).toBeGreaterThan(0);
  for (const row of offline) {
    expect(row.querySelector(".history-row-badge")?.textContent).toBe(table.en!["row.offline"]);
    expect(row.getAttribute("aria-disabled")).toBe("true");
  }
  await act(async () => {
    offline[0]!.dispatchEvent(new dom.window.MouseEvent("dblclick", { bubbles: true }));
  });
  expect(provider.last(ACTION_RUN)).toBeUndefined();
  await contextMenu(offline[0]!);
  const open = dom.window.document.querySelector<HTMLElement>('[role="menuitem"]')!;
  expect(open.getAttribute("aria-disabled") ?? String(open.hasAttribute("data-disabled"))).toBe("true");
});

test("each kind's row has the Swift page's context menu, and every row can be removed", async () => {
  await mount();
  const expected: Record<string, string[]> = {
    Pages: ["Open", "Open in New Tab", "Copy URL", "Remove All from This Site", "Remove from History"],
    Locations: ["Go To", "Remove from History"],
    Commands: ["Run Again", "Copy Command", "Remove from History"],
    Agents: ["Resume Agent Session", "Copy Session ID", "Remove from History"],
  };
  for (const [chip, labels] of Object.entries(expected)) {
    await click(button(chip));
    const row = rows().find((item) => !item.classList.contains("unavailable"))!;
    await contextMenu(row);
    expect(menuLabels().map((label) => label?.replace(/…$/, ""))).toEqual(labels);
    await key(dom.window.document.querySelector<HTMLElement>('[role="menu"]')!, "Escape");
  }
});

test("Clear History offers each range and clears only the kind the chip shows", async () => {
  const { provider } = await mount();
  await click(button("Clear History…"));
  expect(menuLabels()).toEqual(["Last Hour", "Today", "Last 7 Days", "Last 4 Weeks", "All Time"]);
  await click(menuItem("Today")!);
  expect(provider.last(HistoryOps.clear)).toMatchObject({ range: "today" });
  expect((provider.last(HistoryOps.clear)?.kinds as string[] | undefined) ?? []).toEqual([]);

  await click(button("Commands"));
  await click(button("Clear History…"));
  await click(menuItem("Last Hour")!);
  expect(provider.last(HistoryOps.clear)).toMatchObject({ range: "hour", kinds: ["command"] });

  // The daemon owns the trail (cx-hnmbt.12), so Clear also works under that chip.
  await click(button("Locations"));
  await click(button("Clear History…"));
  await click(menuItem("All Time")!);
  expect(provider.last(HistoryOps.clear)).toMatchObject({ range: "all", kinds: ["location"] });
});

test("in Japanese every string of the page is the Japanese one", async () => {
  expect(Object.keys(table.ja!).sort()).toEqual(Object.keys(table.en!).sort());
  await mount(["ja"]);
  expect(host.querySelector(".history-title")?.textContent).toBe(table.ja!["page.title"]);
  expect(host.querySelector<HTMLInputElement>(".history-search")?.placeholder).toBe(table.ja!["page.search"]);
  const chips = [...host.querySelectorAll<HTMLElement>('[role="tab"]')].map((chip) => chip.textContent);
  expect(chips).toEqual(
    ["filter.all", "filter.pages", "filter.locations", "filter.commands", "filter.agents", "filter.closed"].map(
      (id) => table.ja![id],
    ),
  );
  const english = new Set(Object.values(table.en!));
  const visible = [...host.querySelectorAll("button, h1, .history-row-badge")].map((node) => node.textContent ?? "");
  expect(visible.filter((text) => english.has(text))).toEqual([]);
});

const css = ["../src/pages/shared/pageBase.css", "../src/pages/history/styles.css"]
  .map((file) => readFileSync(new URL(file, import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, ""))
  .join("\n");

function declarations(source: string): Array<{ selector: string; property: string; value: string }> {
  const out: Array<{ selector: string; property: string; value: string }> = [];
  for (const [, selector, body] of source.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    for (const declaration of body!.split(";")) {
      const [property, ...value] = declaration.split(":");
      if (property?.trim() && value.length)
        out.push({ selector: selector!.trim(), property: property.trim(), value: value.join(":").trim() });
    }
  }
  return out;
}

test("one background: html paints the web theme surface, body and every container stay transparent", () => {
  const fills = declarations(css).filter((item) => /^background(-color)?$/.test(item.property));
  const on = (name: string) => fills.filter((item) => item.selector.split(",").some((part) => part.trim() === name));
  expect(on("html").map((item) => item.value)).toEqual(["var(--cmux-surface-background, transparent)"]);
  expect(on("body").map((item) => item.value)).toEqual(["transparent"]);
  const containers = /^\.history-(page|header|list|group|chips|title-row|row-text)$/;
  expect(
    fills.filter(
      (item) => item.value !== "transparent" && item.selector.split(",").some((part) => containers.test(part.trim())),
    ),
  ).toEqual([]);
});

test("Reduce Motion: the page has no motion outside a no-preference guard", () => {
  expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\)/);
  const unguarded = css.replace(/@media \(prefers-reduced-motion: no-preference\)\s*\{[\s\S]*?\}\s*\}/g, "");
  const motion = declarations(unguarded).filter(
    (item) => /^(transition|animation)(-|$)/.test(item.property) && !/^(none|0s?)$/.test(item.value),
  );
  expect(motion).toEqual([]);
});
