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
    expect([...menu()!.querySelectorAll(".acpmux-mp-harness")].map((row) => row.textContent)).toEqual([
      "Claude Code",
      "Codex",
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

  test("number keys pick within the open model section and Ctrl-N/P moves the active row", async () => {
    await render();
    await act(async () => modelButton().click());
    const input = menu()!.querySelector<HTMLInputElement>("input[role=combobox]")!;
    await key(input, "ArrowUp");
    expect(modelRows()[0]!.getAttribute("aria-selected")).toBe("true");
    await ctrlKey(input, "n");
    expect(modelRows()[1]!.getAttribute("aria-selected")).toBe("true");
    await key(input, "1");
    expect(calls).toEqual(["model claude-opus-4-1"]);
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

  test.each([
    ["harness row", ".acpmux-mp-harness"],
    // Use the control's accessible contract here instead of its layout class. The
    // filter is the only pressed Model button inside the open picker, and this
    // keeps the focus/escape test independent of class-name serialization.
    ["favorites filter", 'button[aria-label="Model"][aria-pressed]'],
    ["model row", ".acpmux-mp-row"],
    ["favorite button", ".acpmux-mp-favorite"],
  ])("Escape from the %s closes the picker and restores the trigger", async (_name, selector) => {
    await render();
    await act(async () => modelButton().click());
    const control = menu()!.querySelector<HTMLElement>(selector)!;
    control.focus();
    await key(control, "Escape");
    expect(menu() === null).toBe(true);
    expect(doc.activeElement === modelButton()).toBe(true);
    expect(calls).toEqual([]);
  });

  test("an Escape consumed by a picker control keeps the picker open", async () => {
    await render();
    await act(async () => modelButton().click());
    const favorite = menu()!.querySelector<HTMLElement>(".acpmux-mp-favorite")!;
    favorite.focus();
    favorite.addEventListener("keydown", (event) => event.preventDefault(), { once: true });
    await key(favorite, "Escape");
    expect(menu() !== null).toBe(true);
    expect(doc.activeElement === favorite).toBe(true);
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

  test("rows are one line with stable command hotkeys and a star on the row", async () => {
    await render();
    await act(async () => modelButton().click());
    expect(modelRows()[0]!.querySelector(".acpmux-mp-row-subtitle")).toBeNull();
    expect(modelRows()[0]!.querySelector(".acpmux-mp-hotkey")?.textContent).toBe("⌘1");
    const favorite = modelRows()[0]!.parentElement!.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!;
    expect(favorite.getAttribute("aria-pressed")).toBe("false");
    await act(async () => favorite.click());
    expect(modelRows()[0]!.parentElement!.querySelector(".acpmux-mp-favorite")!.getAttribute("aria-pressed")).toBe(
      "true",
    );
  });

  // Leo (dogfood 2026-10-08, A1): the lone star in a big left column filtered every harness down to
  // "No matching models". Starred models get their own section on top instead; nothing filters.
  test("starred models sit in a Starred section on top, and no toggle hides the other models", async () => {
    await render();
    await act(async () => modelButton().click());
    expect(menu()!.querySelector(".acpmux-mp-harness-favorites")).toBeNull();
    const labels = () => modelRows().map((row) => row.querySelector(".acpmux-menu-label")?.textContent);
    const sonnet = modelRows().find((row) => row.textContent?.includes("Sonnet 5.5"))!;
    await act(async () => sonnet.parentElement!.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!.click());
    expect(labels()).toEqual(["Sonnet 5.5", "Opus 4.1", "Opus 5.5"]);
    const sections = [...menu()!.querySelectorAll(".acpmux-mp-models .acpmux-mp-section")].map((s) => s.textContent);
    expect(sections[0]).toBe("Starred");
    const codex = [...menu()!.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (row) => row.textContent === "Codex",
    )!;
    await act(async () => codex.click());
    expect(labels()).toEqual(["o3", "GPT-6-Astra"]);
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
