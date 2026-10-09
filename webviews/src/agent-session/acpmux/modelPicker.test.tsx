import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  IS_REACT_ACT_ENVIRONMENT: true,
  localStorage: { getItem: () => null, setItem: () => {} },
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerPickers } = await import("./ComposerPickers");

const doc = dom.window.document;
const effort = {
  id: "effort",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "low", name: "Low" },
    { value: "high", name: "High" },
  ],
};
const snapshot = (): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [
    {
      id: "claude",
      name: "Claude Code",
      models: [
        { id: "claude-opus-5-5", name: "Opus 5.5" },
        { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
        { id: "claude-opus-4-1", name: "Opus 4.1" },
      ],
    },
    {
      id: "claude-sr",
      name: "Claude Code",
      models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }],
    },
    {
      id: "codex",
      name: "Codex",
      models: [
        { id: "gpt-6-astra", name: "GPT-6-Astra" },
        { id: "o3", name: "o3" },
      ],
    },
  ],
  summary: { sessionId: "s", harness: "claude", model: "claude-opus-5-5", configOptions: [effort] },
});

describe("T3 model picker", () => {
  let root: ReturnType<typeof createRoot>;
  let calls: string[];
  const render = async (value = snapshot()) =>
    act(async () =>
      root.render(
        createElement(ComposerPickers, {
          snapshot: value,
          onModel: (model: string) => calls.push(`model ${model}`),
          onMode: () => {},
          onEffort: (config: string, value: string) => calls.push(`config ${config} ${value}`),
          onHarness: (harness: string) => calls.push(`harness ${harness}`),
        }),
      ),
    );
  const modelButton = () => doc.querySelector<HTMLButtonElement>('[aria-label="Model"].acpmux-picker-button')!;
  const menu = () => doc.querySelector<HTMLElement>(".acpmux-mp");
  const modelRows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-mp-models .acpmux-mp-row")];
  const key = (target: Element, name: string) =>
    act(async () =>
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true })),
    );
  const ctrlKey = (target: Element, name: string) =>
    act(async () =>
      target.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: name, ctrlKey: true, bubbles: true, cancelable: true }),
      ),
    );

  beforeEach(() => {
    calls = [];
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("uses one harness/model button, deduplicates Claude Code, and keeps effort separate", async () => {
    await render();
    expect(modelButton().querySelector(".agent-mark")?.getAttribute("data-agent")).toBe("claude");
    expect(modelButton().textContent).toContain("Opus 5.5");
    expect(doc.querySelector('[aria-label="Effort"].acpmux-picker-button')?.textContent).toContain("High");
    await act(async () => modelButton().click());
    expect(menu()).not.toBeNull();
    expect(menu()!.querySelectorAll(".acpmux-mp-harness")).toHaveLength(2);
    // The menu grows up from the chip: the running harness is the bottom row, nearest it.
    expect([...menu()!.querySelectorAll(".acpmux-mp-harness")].map((row) => row.textContent)).toEqual([
      "Codex",
      "Claude Code",
    ]);
  });

  test("focuses the real search input and keeps model order stable across opens", async () => {
    await render();
    await act(async () => modelButton().click());
    const input = menu()!.querySelector<HTMLInputElement>("input[role=combobox]")!;
    expect(doc.activeElement).toBe(input);
    const labels = () => modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent);
    const first = labels();
    expect(first).toEqual(["Opus 4.1", "Opus 5.5", "Sonnet 5.5"]);
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, "sonnet");
    await act(async () => input.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
    expect(labels()).toEqual(["Sonnet 5.5"]);
    await key(input, "Enter");
    expect(calls).toEqual(["model claude-sonnet-5-5"]);
    await act(async () => modelButton().click());
    expect(labels()).toEqual(first);
  });

  test("number keys count up from the chip and Ctrl-N/P moves the active row", async () => {
    await render();
    await act(async () => modelButton().click());
    const input = menu()!.querySelector<HTMLInputElement>("input[role=combobox]")!;
    // The running model is the active row when the menu opens.
    expect(modelRows()[1]!.getAttribute("aria-selected")).toBe("true");
    await key(input, "ArrowUp");
    expect(modelRows()[0]!.getAttribute("aria-selected")).toBe("true");
    await ctrlKey(input, "n");
    expect(modelRows()[1]!.getAttribute("aria-selected")).toBe("true");
    // 1 is the bottom row, nearest the chip.
    await key(input, "1");
    expect(calls).toEqual(["model claude-sonnet-5-5"]);
  });

  test("a different harness shows its models, then starts that harness on a model pick", async () => {
    await render();
    await act(async () => modelButton().click());
    const codex = [...menu()!.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (row) => row.textContent === "Codex",
    )!;
    await act(async () => codex.click());
    expect(modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
      "o3",
      "GPT-6-Astra",
    ]);
    await act(async () => modelRows()[0]!.click());
    expect(calls).toEqual(["harness codex"]);
    expect(menu()).toBeNull();
  });

  test("the trigger toggles closed and the model shortcut opens the picker", async () => {
    await render();
    await act(async () => modelButton().click());
    expect(modelButton().getAttribute("aria-expanded")).toBe("true");
    await act(async () => modelButton().click());
    expect(modelButton().getAttribute("aria-expanded")).toBe("false");
    await act(async () => {
      dom.window.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "m",
          metaKey: true,
          ctrlKey: true,
          shiftKey: true,
          bubbles: true,
        }),
      );
    });
    expect(modelButton().getAttribute("aria-expanded")).toBe("true");
  });

  test("shows the harness fast-mode toggle when ACP exposes it", async () => {
    await render({
      ...snapshot(),
      summary: {
        ...snapshot().summary!,
        configOptions: [
          effort,
          {
            id: "fast-mode",
            name: "Fast mode",
            currentValue: "off",
            options: [
              { value: "off", name: "Off" },
              { value: "on", name: "On" },
            ],
          },
        ],
      },
    });
    await act(async () => modelButton().click());
    const fast = doc.querySelector<HTMLButtonElement>(".acpmux-mp-fast")!;
    expect(fast.textContent).toContain("Off");
    await act(async () => fast.click());
    expect(calls).toEqual(["config fast-mode on"]);
  });

  test("rows are one line with hotkeys counted from the chip and a star on the row", async () => {
    await render();
    await act(async () => modelButton().click());
    const rows = modelRows();
    expect(rows[0]!.querySelector(".acpmux-mp-row-subtitle")).toBeNull();
    expect(rows.map((row) => row.querySelector(".acpmux-mp-hotkey")?.textContent ?? "")).toEqual(["⌘3", "⌘2", "⌘1"]);
    const favorite = rows[0]!.parentElement!.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!;
    expect(favorite.getAttribute("aria-pressed")).toBe("false");
    await act(async () => favorite.click());
    const starred = modelRows().find((row) => row.textContent?.includes("Opus 4.1"))!;
    expect(starred.parentElement!.querySelector(".acpmux-mp-favorite")!.getAttribute("aria-pressed")).toBe("true");
    expect(starred.parentElement!.querySelector(".acpmux-mp-favorite")!.textContent).toBe("★");
  });

  // Leo (dogfood 2026-10-08, picker v2): "why are there even sections; a highlight shows you it is
  // selected". One flat list per harness: starred models sort to the bottom, nearest the chip, and
  // the running model is highlighted and checked. No headers anywhere.
  test("one flat list per harness: starred models sink to the bottom, the running one is highlighted", async () => {
    await render();
    await act(async () => modelButton().click());
    expect(menu()!.querySelector(".acpmux-mp-harness-favorites")).toBeNull();
    const labels = () => modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent);
    const current = modelRows().find((row) => row.getAttribute("aria-checked") === "true")!;
    expect(current.textContent).toContain("Opus 5.5");
    expect(current.classList.contains("acpmux-mp-current")).toBe(true);
    expect(current.querySelector("svg")).not.toBeNull();
    const opus41 = modelRows().find((row) => row.textContent?.includes("Opus 4.1"))!;
    await act(async () => opus41.parentElement!.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!.click());
    expect(labels()).toEqual(["Opus 5.5", "Sonnet 5.5", "Opus 4.1"]);
    expect(menu()!.querySelector(".acpmux-mp-section")).toBeNull();
    const codex = [...menu()!.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (row) => row.textContent === "Codex",
    )!;
    await act(async () => codex.click());
    expect(labels()).toEqual(["o3", "GPT-6-Astra"]);
    expect(menu()!.querySelector(".acpmux-mp-section")).toBeNull();
  });

  test("resting on a harness branches its models out beside it, without a click", async () => {
    await render();
    await act(async () => modelButton().click());
    const codex = [...menu()!.querySelectorAll<HTMLElement>(".acpmux-mp-harness")].find(
      (row) => row.textContent === "Codex",
    )!;
    await act(async () => codex.dispatchEvent(new dom.window.Event("pointerenter")));
    expect(doc.querySelector(".acpmux-mp-models")!.getAttribute("aria-label")).toBe("Codex");
    expect(modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
      "o3",
      "GPT-6-Astra",
    ]);
  });

  test("typing searches every harness, and a pick in another harness starts it", async () => {
    await render();
    await act(async () => modelButton().click());
    const input = menu()!.querySelector<HTMLInputElement>("input[role=combobox]")!;
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, "astra");
    await act(async () => input.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
    const rows = modelRows();
    expect(rows.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual(["GPT-6-Astra"]);
    // A match names its harness by its mark.
    expect(rows[0]!.querySelector(".agent-mark")?.getAttribute("data-agent")).toBe("openai");
    await key(input, "Enter");
    expect(calls).toEqual(["harness codex"]);
  });

  // Leo (dogfood 2026-10-08, picker v2): too many models at once. A harness with more than a
  // handful shows a short list (starred, the running model, the flagship and the newest) under a
  // "More models" row at the top, furthest from the chip. Search still matches every model, and
  // starring a model from More promotes it into the short list.
  test("a long catalog shows a short list under a More models row", async () => {
    const long = snapshot();
    long.catalog![0]!.models = [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
      { id: "claude-opus-4-1", name: "Opus 4.1" },
      { id: "claude-opus-4", name: "Opus 4" },
      { id: "claude-sonnet-4", name: "Sonnet 4" },
      { id: "claude-sonnet-3-7", name: "Sonnet 3.7" },
      { id: "claude-haiku-3-5", name: "Haiku 3.5" },
    ];
    await render(long);
    await act(async () => modelButton().click());
    const labels = () => modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent);
    const more = () => doc.querySelector<HTMLButtonElement>(".acpmux-mp-models .acpmux-mp-more");
    expect(labels()).toEqual(["Opus 5.5", "Sonnet 5.5"]);
    expect(more()?.textContent).toContain("More models");
    expect(doc.querySelector(".acpmux-mp-models")!.firstElementChild).toBe(more());
    const input = menu()!.querySelector<HTMLInputElement>("input[role=combobox]")!;
    const type = async (text: string) => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
      await act(async () => input.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
    };
    await type("haiku");
    expect(labels()).toEqual(["Haiku 3.5", "Haiku 4.5"]);
    expect(more()).toBeNull();
    await type("");
    await act(async () => more()!.click());
    expect(labels()).toHaveLength(8);
    expect(labels()[0]).toBe("Haiku 3.5");
    const haiku = modelRows().find((row) => row.textContent?.includes("Haiku 3.5"))!;
    await act(async () => haiku.parentElement!.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!.click());
    await act(async () => modelButton().click());
    await act(async () => modelButton().click());
    expect(labels()).toEqual(["Opus 5.5", "Sonnet 5.5", "Haiku 3.5"]);
    expect(more()).not.toBeNull();
  });

  test("no empty footer band: refresh and fast mode sit in the search row", async () => {
    await render({
      ...snapshot(),
      summary: {
        ...snapshot().summary!,
        configOptions: [
          effort,
          {
            id: "fast-mode",
            name: "Fast mode",
            currentValue: "off",
            options: [
              { value: "off", name: "Off" },
              { value: "on", name: "On" },
            ],
          },
        ],
      },
    });
    await act(async () => modelButton().click());
    expect(menu()!.querySelector(".acpmux-mp-footer")).toBeNull();
    expect(menu()!.querySelector(".acpmux-mp-search .acpmux-mp-fast")).not.toBeNull();
  });

  test("the menu sizes to its content, never truncates a harness name, and takes the shared popup shadow", async () => {
    const css = await Bun.file(new URL("./modelPicker.css", import.meta.url)).text();
    const rule = (selector: string) => {
      const at = css.indexOf(`${selector} {`);
      return at < 0 ? "" : css.slice(at, css.indexOf("}", at));
    };
    expect(rule(".acpmux-menu.acpmux-mp-t3")).toContain("width: max-content");
    expect(rule(".acpmux-mp-harness-name")).toContain("white-space: nowrap");
    expect(rule(".acpmux-mp-harness-name")).not.toContain("ellipsis");
    expect(rule(".acpmux-menu.acpmux-mp-t3")).toContain("var(--ui-popup-shadow");
  });

  // Leo (dogfood 2026-10-08, A1): after picking Claude Code the chip drew the Codex mark beside
  // "Claude Code". The chip draws one harness: the running one, or the one a switch is starting.
  test("the chip keeps one harness's mark and name while another harness is browsed", async () => {
    await render();
    await act(async () => modelButton().click());
    const codex = [...menu()!.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (row) => row.textContent === "Codex",
    )!;
    await act(async () => codex.click());
    expect(modelButton().querySelector(".agent-mark")?.getAttribute("data-agent")).toBe("claude");
    expect(modelButton().textContent).toContain("Opus 5.5");
    expect(modelButton().textContent).not.toContain("Codex");
  });

  test("a harness switch in flight draws the new harness's mark and name together", async () => {
    await render({ ...snapshot(), switching: { harness: "codex", name: "Codex", phase: "starting" } });
    // Codex draws the OpenAI mark.
    expect(modelButton().querySelector(".agent-mark")?.getAttribute("data-agent")).toBe("openai");
    expect(modelButton().textContent).toContain("Codex");
    expect(modelButton().textContent).not.toContain("Opus 5.5");
  });
});
