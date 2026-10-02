import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "localStorage"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerPickers } = await import("./ComposerPickers");
const { HOVER_INTENT_MS } = await import("./modelPickerVariant");
type Variant = "cascade" | "columns" | "recents";

const doc = dom.window.document;
const effort = (currentValue: string) => ({
  id: "effort",
  category: "thought_level",
  currentValue,
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
});
const snapshot = (model = "claude-opus-5-5", currentEffort = "high"): AcpmuxSnapshot => ({
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
        { id: "claude-haiku-4-5", name: "Haiku 4.5" },
        { id: "claude-fable-1-5", name: "Fable 1.5" },
        { id: "claude-opus-5", name: "Opus 5" },
        { id: "claude-opus-4-6", name: "Opus 4.6" },
        { id: "claude-opus-4-1", name: "Opus 4.1" },
        { id: "claude-sonnet-5", name: "Sonnet 5" },
        { id: "claude-sonnet-4-6", name: "Sonnet 4.6" },
      ],
    },
    {
      id: "codex",
      name: "Codex",
      models: [
        { id: "gpt-6-astra", name: "GPT-6-Astra" },
        { id: "o3", name: "o3" },
        { id: "qwen3-coder", name: "Qwen3 Coder" },
      ],
    },
  ],
  summary: { sessionId: "s", harness: "claude", model, configOptions: [effort(currentEffort)] },
});
/// Recents, newest first: one Codex combo the Claude session must never show.
const RECENTS = [
  { harness: "claude", model: "claude-sonnet-5", effort: "low", effortName: "Low" },
  { harness: "codex", model: "gpt-6-astra", effort: "high", effortName: "High" },
  { harness: "claude", model: "claude-opus-5-5", effort: "high", effortName: "High" },
  { harness: "claude", model: "claude-haiku-4-5", effort: "medium", effortName: "Medium" },
];
const OTHER_HARNESS_MODELS = ["GPT-6-Astra", "o3", "Qwen3 Coder"];

for (const variant of ["cascade", "columns", "recents"] as Variant[]) {
  describe(`model picker variant: ${variant}`, () => {
    let root: ReturnType<typeof createRoot>;
    let calls: string[];
    const store = new Map<string, string>();
    const render = async (value: AcpmuxSnapshot) =>
      act(async () =>
        root.render(
          createElement(ComposerPickers, {
            snapshot: value,
            variant,
            settleMs: 60_000,
            onModel: (id: string) => {
              calls.push(`model ${id}`);
            },
            onMode: () => {},
            onEffort: (config: string, id: string) => {
              calls.push(`effort ${config} ${id}`);
            },
            onHarness: (id: string) => {
              calls.push(`harness ${id}`);
            },
          }),
        ),
      );
    const chip = () => doc.querySelector<HTMLButtonElement>('[aria-label="Model"].acpmux-picker-button')!;
    const menu = () => doc.querySelector<HTMLElement>(".acpmux-mp");
    const rows = (within: ParentNode = menu()!) => [...within.querySelectorAll<HTMLElement>(".acpmux-mp-row")];
    const row = (label: string, within?: ParentNode) =>
      rows(within).find((candidate) => candidate.querySelector(".acpmux-menu-label")?.textContent === label);
    const labels = (within?: ParentNode) =>
      rows(within).map((candidate) => candidate.querySelector(".acpmux-menu-label")!.textContent);
    const press = (target: Element) =>
      act(async () => {
        target.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
      });
    const key = (name: string) =>
      act(async () => {
        chip().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
      });
    const type = async (text: string) => {
      for (const char of text) await key(char);
    };
    const enter = (target: Element) =>
      act(async () => {
        target.dispatchEvent(new dom.window.PointerEvent("pointerover", { bubbles: true }));
      });
    const wait = (ms: number) => act(() => new Promise((resolve) => setTimeout(resolve, ms)));
    const open = async () => {
      await act(async () => chip().click());
      expect(menu()).not.toBeNull();
      // Recents-first keeps the layers behind "More models"; it drills in place.
      if (variant === "recents") await press(row("More models")!);
    };

    beforeEach(() => {
      calls = [];
      store.clear();
      store.set("cmux.acpmux.recentModels", JSON.stringify(RECENTS));
      globals.localStorage = {
        getItem: (name: string) => store.get(name) ?? null,
        setItem: (name: string, value: string) => store.set(name, value),
      };
      root = createRoot(doc.getElementById("root")!);
    });
    afterEach(async () => {
      await act(async () => root.unmount());
    });

    test("opens with the numbered recents nearest the chip, 1 at the very bottom", async () => {
      await render(snapshot());
      expect(chip().textContent).toBe("Opus 5.5");
      await act(async () => chip().click());
      expect(chip().getAttribute("aria-expanded")).toBe("true");
      const recentRows = rows().filter((candidate) => candidate.querySelector(".acpmux-menu-hint"));
      const recentText = recentRows.map((candidate) => candidate.textContent);
      if (variant === "columns") {
        // A strip along the bottom edge, the last thing in the popover.
        const strip = menu()!.lastElementChild!;
        expect(strip.className).toBe("acpmux-mp-strip");
        expect(rows(strip).map((candidate) => candidate.textContent)).toEqual([
          "1Sonnet 5Low",
          "2Opus 5.5High",
          "3Haiku 4.5Medium",
        ]);
      } else {
        expect(recentText).toEqual(["3Haiku 4.5Medium", "2Opus 5.5High", "1Sonnet 5Low"]);
        // They are the menu's last rows, the newest last.
        expect(rows().slice(-3)).toEqual(recentRows);
      }
      // The current combo is checked.
      expect(
        recentRows.find((candidate) => candidate.textContent?.includes("Opus 5.5"))!.getAttribute("aria-checked"),
      ).toBe("true");
    });

    test("hovering a family opens its models after the intent delay, default first", async () => {
      await render(snapshot());
      await open();
      const sonnet = row("Sonnet")!;
      expect(sonnet).toBeDefined();
      await enter(sonnet);
      // Not at once: the pointer may be passing through.
      expect(labels().includes("Sonnet 4.6")).toBe(false);
      await wait(HOVER_INTENT_MS + 60);
      const level =
        variant === "columns"
          ? menu()!.querySelector('[data-column="model"]')!
          : menu()!.querySelector('[data-mp-sub="0"]')!;
      expect(level).not.toBeNull();
      const shown = labels(level);
      // Best (the recent Sonnet 5) last, next to the row and the chip; the newest next.
      expect(shown).toEqual(["Sonnet 4.6", "Sonnet 5.5", "Sonnet 5"]);
    });

    test("one click on a family lands on its last-used model, then that model's recent effort", async () => {
      await render(snapshot());
      await open();
      await press(row("Sonnet")!);
      expect(calls).toEqual(["model claude-sonnet-5"]);
      expect(menu()).toBeNull();
      // The agent reports the model; the effort follows.
      await render(snapshot("claude-sonnet-5", "high"));
      expect(calls).toEqual(["model claude-sonnet-5", "effort effort low"]);
      await render(snapshot("claude-sonnet-5", "low"));
      // A family never used lands on its newest model and keeps the effort the session ran (Low).
      calls.length = 0;
      await open();
      await press(row("Fable")!);
      expect(calls).toEqual(["model claude-fable-1-5"]);
      await render(snapshot("claude-fable-1-5", "medium"));
      expect(calls).toEqual(["model claude-fable-1-5", "effort effort low"]);
    });

    test("number keys pick a recent combo", async () => {
      await render(snapshot());
      await act(async () => chip().click());
      await key("3");
      expect(calls).toEqual(["model claude-haiku-4-5"]);
      expect(menu()).toBeNull();
      await render(snapshot("claude-haiku-4-5", "high"));
      expect(calls).toEqual(["model claude-haiku-4-5", "effort effort medium"]);
      // A key past the recents does nothing.
      await act(async () => chip().click());
      await key("9");
      expect(menu()).not.toBeNull();
    });

    test("typing filters this harness's models; Return picks the best match, Escape clears then closes", async () => {
      await render(snapshot());
      await act(async () => chip().click());
      // Columns list the matches in place of the columns, over the recents strip.
      const matches = () =>
        labels(variant === "columns" ? menu()!.querySelector('[data-column="filter"]')! : undefined);
      await type("son");
      expect(doc.querySelector(".acpmux-mp .acpmux-menu-search")!.textContent).toBe("son");
      // Best match nearest the chip.
      expect(matches()).toEqual(["Sonnet 4.6", "Sonnet 5", "Sonnet 5.5"]);
      // Digits after a query are part of it.
      await type(" 4");
      expect(matches()).toEqual(["Sonnet 4.6"]);
      await key("Backspace");
      await key("Backspace");
      await type("gpt");
      expect(matches()).toEqual(["No matching models"]);
      await key("Escape");
      expect(doc.querySelector(".acpmux-mp .acpmux-menu-search")!.textContent).toBe("Type to search models");
      await type("sonnet 5.5");
      await key("Enter");
      expect(calls).toEqual(["model claude-sonnet-5-5"]);
      await act(async () => chip().click());
      await key("Escape");
      expect(menu()).toBeNull();
    });

    test("models another harness runs never render, however far the menu opens", async () => {
      await render(snapshot());
      await open();
      // Open every layer and fold there is.
      for (let round = 0; round < 2; round += 1)
        for (const candidate of rows()) {
          if (!candidate.isConnected) continue;
          if (candidate.classList.contains("acpmux-mp-more")) await press(candidate);
          else if (candidate.getAttribute("aria-haspopup")) {
            await enter(candidate);
            await wait(HOVER_INTENT_MS + 20);
          } else continue;
          for (const name of OTHER_HARNESS_MODELS) expect(menu()!.textContent).not.toContain(name);
        }
      await type("o3");
      for (const name of OTHER_HARNESS_MODELS) expect(labels()).not.toContain(name);
      // The other harness is offered only as a new chat.
      expect(menu()!.textContent).not.toContain("Codex");
    });
  });
}
