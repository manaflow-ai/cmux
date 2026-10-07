import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
const { proseMirrorGlobals, promptField, typeInto } = await import("./promptFieldTesting");
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
  // The context popover is the shared Base UI Popover (src/ui), which animates on frames.
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// Base UI reaches for DOM classes by name.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) =>
    /^(HTML|SVG|Element|Event|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Shadow|Document|Mutation|Resize|getComputedStyle|Node)/.test(
      key,
    ) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { ComposerPickers, isPlan, loadRecents, rememberCombo, unrestricted } = await import("./ComposerPickers");
const { openPicker, pickerLabels } = await import("./pickerOpeners");

const doc = dom.window.document;
const snapshot = (
  summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {},
  isWorking = false,
): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking,
  queue: [],
  canLoadOlder: false,
  catalog: [
    {
      id: "codex",
      name: "Codex",
      models: [
        { id: "astra", name: "6 Astra" },
        { id: "sol", name: "6.1 Sol" },
      ],
    },
  ],
  summary: { sessionId: "s", harness: "codex", model: "astra", ...summary },
});
const effort = {
  id: "reasoning_effort",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};
const modes = {
  currentModeId: "ask",
  availableModes: [
    { id: "ask", name: "Ask for approval", description: "Always ask" },
    { id: "bypassPermissions", name: "Full access", description: "Unrestricted" },
  ],
};

/// Milkdown makes the composer's editor a task after it mounts.
const ready = () => act(() => new Promise((resolve) => setTimeout(resolve, 10)));

describe("acpmux composer pickers", () => {
  let root: ReturnType<typeof createRoot>;
  let calls: string[];
  // Recents record after the selection settles. The settle checks wait here until a test runs
  // them (settle), so a combo the pane only passes through between two renders never counts,
  // however slowly the machine runs.
  const pendingSettles = new Set<() => void>();
  const settleTimer = (run: () => void) => {
    const job = () => {
      pendingSettles.delete(job);
      run();
    };
    pendingSettles.add(job);
    return () => void pendingSettles.delete(job);
  };
  const settle = () => act(async () => [...pendingSettles].forEach((job) => job()));
  const render = async (value: AcpmuxSnapshot, extra: { showPlan?: boolean; onCompact?(): void } = {}) =>
    act(async () =>
      root.render(
        createElement(ComposerPickers, {
          ...extra,
          snapshot: value,
          settleTimer,
          // Room beside the menu for the cascade; the model picker's tests cover the narrow drill.
          measurePickerRoom: () => 600,
          onModel: (id: string) => {
            calls.push(`model ${id}`);
          },
          onMode: (id: string) => {
            calls.push(`mode ${id}`);
          },
          onEffort: (config: string, id: string) => {
            calls.push(`effort ${config} ${id}`);
          },
        }),
      ),
    );
  const button = (label: string) =>
    doc.querySelector<HTMLButtonElement>(`[aria-label="${label}"].acpmux-picker-button`);
  const options = () =>
    [...doc.querySelectorAll("[role=option]")].map(
      (option) => `${option.textContent}${option.getAttribute("aria-checked") === "true" ? " *" : ""}`,
    );
  /// The model picker's rows by label, the checked one starred.
  const rowLabels = () =>
    [...doc.querySelectorAll(".acpmux-mp-row")].map(
      (row) =>
        `${row.querySelector(".acpmux-menu-label")?.textContent}${row.getAttribute("aria-checked") === "true" ? " *" : ""}`,
    );
  const key = async (target: Element, name: string) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
  /// The model menu's Reasoning row, opened to its slider (the menu opens first when closed).
  const openReasoning = async () => {
    const model = button("Model")!;
    if (model.getAttribute("aria-expanded") !== "true") await act(async () => model.click());
    const row = [...doc.querySelectorAll<HTMLElement>(".acpmux-mp-row")].find(
      (candidate) => candidate.querySelector(".acpmux-menu-label")?.textContent === "Reasoning",
    )!;
    // Menu rows act on mousedown, so the chip keeps focus.
    await act(async () => {
      row.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    return doc.querySelector<HTMLInputElement>(".acpmux-effort-range")!;
  };
  /// Moves a slider through React's change handler: react-dom may load before the DOM exists (see typeInto).
  const slide = (range: HTMLInputElement, value: string) =>
    act(async () => {
      range.value = value;
      const props = (range as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
        Object.keys(range).find((key) => key.startsWith("__reactProps$"))!
      ]!;
      props.onChange({ target: range });
    });

  beforeEach(() => {
    calls = [];
    pendingSettles.clear();
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("one chip names the model and its effort; its menu holds the model and the reasoning slider", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const model = button("Model")!;
    // The model in primary text, the effort after it in secondary text, one chevron, no second chip.
    expect(model.querySelector(".acpmux-model-name")!.textContent).toBe("6 Astra");
    expect(model.querySelector(".acpmux-model-effort")!.textContent).toBe("High");
    expect(model.querySelectorAll("svg")).toHaveLength(1);
    expect(button("Effort")).toBeNull();
    expect(button("Mode")).toBeNull();
    await act(async () => model.click());
    const menu = doc.querySelector(".acpmux-mp[role=menu]")!;
    const astra = [...menu.querySelectorAll("[role=menuitemradio]")].find(
      (row) => row.querySelector(".acpmux-menu-label")?.textContent === "6 Astra",
    );
    expect(astra!.getAttribute("aria-checked")).toBe("true");
    // Typing filters the models; Return picks the best match.
    for (const char of "sol") await key(model, char);
    await key(model, "Enter");
    expect(calls).toEqual(["model sol"]);
    expect(doc.querySelector(".acpmux-mp")).toBeNull();
    // The same menu's Reasoning row opens the stepped slider, one stop per level.
    const range = await openReasoning();
    expect([range.min, range.max, range.value]).toEqual(["0", "1", "1"]);
    await slide(range, "0");
    expect(calls).toEqual(["model sol", "effort reasoning_effort medium"]);
  });

  test("the chip shows no effort for the agent's default level", async () => {
    await render(
      snapshot({
        configOptions: [{ ...effort, currentValue: "default", options: [{ value: "default", name: "Default" }] }],
      }),
    );
    expect(button("Model")!.textContent).toBe("6 Astra");
    expect(doc.querySelector(".acpmux-model-effort")).toBeNull();
  });

  test("the permission chip stays in the bar when Plan lives in the + menu", async () => {
    await render(snapshot({ modes: { ...modes, currentModeId: "bypassPermissions" } }), { showPlan: false });
    expect(button("Mode")!.textContent).toBe("Full access");
    expect(button("Mode")!.closest(".acpmux-mode")!.classList.contains("acpmux-unrestricted")).toBe(true);
    expect(doc.querySelector(".acpmux-plan")).toBeNull();
  });

  test("arrows and Enter pick from the menu, and Escape closes it back to the button", async () => {
    await render(snapshot({ modes }));
    const mode = button("Mode")!;
    await key(mode, "ArrowDown");
    expect(mode.getAttribute("aria-expanded")).toBe("true");
    expect(doc.getElementById(mode.getAttribute("aria-activedescendant")!)!.textContent).toContain("Ask for approval");
    await key(mode, "ArrowUp");
    expect(doc.getElementById(mode.getAttribute("aria-activedescendant")!)!.textContent).toContain("Full access");
    await key(mode, "Enter");
    expect(calls).toEqual(["mode bypassPermissions"]);
    await key(mode, "ArrowDown");
    await key(mode, "Escape");
    expect(doc.querySelector("[role=listbox]")).toBeNull();
    expect(doc.activeElement).toBe(mode);
    expect(calls).toEqual(["mode bypassPermissions"]);
  });

  test("Space picks on keyup without the button's click reopening the menu, and a shrunk list keeps a row highlighted", async () => {
    const full = { ...modes, currentModeId: "bypassPermissions" };
    await render(snapshot({ modes: full }));
    const mode = button("Mode")!;
    // The highlight opens on the current mode, the last one.
    await key(mode, "ArrowDown");
    expect(doc.getElementById(mode.getAttribute("aria-activedescendant")!)!.textContent).toContain("Full access");
    // A live update drops that option while it is highlighted.
    await render(snapshot({ modes: { ...full, availableModes: [full.availableModes[0]!] } }));
    expect(doc.getElementById(mode.getAttribute("aria-activedescendant")!)!.textContent).toContain("Ask for approval");
    await key(mode, " ");
    expect(mode.getAttribute("aria-expanded")).toBe("true");
    const up = new dom.window.KeyboardEvent("keyup", { key: " ", bubbles: true, cancelable: true });
    await act(async () => {
      mode.dispatchEvent(up);
    });
    expect(up.defaultPrevented).toBe(true);
    expect(calls).toEqual(["mode ask"]);
    expect(mode.getAttribute("aria-expanded")).toBe("false");
  });

  test("the approval menu asks its question over the described modes", async () => {
    await render(snapshot({ modes }));
    await act(async () => button("Mode")!.click());
    const menu = doc.querySelector("[role=listbox]")!;
    expect(menu.getAttribute("aria-label")).toBe("How should the agent's actions be approved?");
    expect(menu.querySelector(".acpmux-menu-heading")!.textContent).toBe("How should the agent's actions be approved?");
    expect(menu.textContent).toContain("Always ask");
  });

  test("a recent combo lands its model, then its effort once the agent reports that model offering it", async () => {
    const catalog = [
      {
        id: "codex",
        name: "Codex",
        models: [
          { id: "astra", name: "6 Astra" },
          { id: "sol", name: "6.1 Sol" },
          { id: "luna", name: "6 Luna" },
          { id: "mini", name: "6 Mini" },
          { id: "nano", name: "6 Nano" },
        ],
      },
    ];
    const long = (summary: Parameters<typeof snapshot>[0]) => ({ ...snapshot(summary), catalog });
    const medium = { ...effort, currentValue: "medium" };
    // The session runs Astra on High, then Sol on Medium: both become recents.
    await render(long({ configOptions: [effort] }));
    await settle();
    // The switch passes through Sol on the old effort before the new one lands; only the settled combo counts.
    await render(long({ model: "sol", configOptions: [effort] }));
    await render(long({ model: "sol", configOptions: [medium] }));
    await settle();
    const model = button("Model")!;
    const recentRows = () =>
      [...doc.querySelectorAll(".acpmux-mp-row")]
        .filter((row) => row.querySelector(".acpmux-menu-hint"))
        .map((row) => `${row.textContent}${row.getAttribute("aria-checked") === "true" ? " *" : ""}`);
    await act(async () => model.click());
    expect(recentRows()).toEqual(["26 AstraHigh", "16.1 SolMedium *"]);
    // One key switches the model, then the effort once the agent reports that model offering it.
    const pickRecent = async (digit: string) => {
      if (model.getAttribute("aria-expanded") !== "true") await act(async () => model.click());
      await key(model, digit);
    };
    await pickRecent("2");
    expect(calls).toEqual(["model astra"]);
    await render(long({ model: "astra", configOptions: [medium] }));
    expect(calls).toEqual(["model astra", "effort reasoning_effort high"]);
    // A model that doesn't offer the stored effort keeps its own.
    await render(long({ model: "sol", configOptions: [medium] }));
    await pickRecent("2");
    await render(long({ model: "astra", configOptions: [{ ...medium, options: [effort.options[0]!] }] }));
    await render(long({ model: "sol", configOptions: [medium] }));
    await render(long({ model: "astra", configOptions: [medium] }));
    expect(calls).toEqual(["model astra", "effort reasoning_effort high", "model astra"]);
    // A combo still waiting when the pane switches sessions doesn't follow into the other session.
    await render(long({ model: "sol", configOptions: [medium] }));
    calls.length = 0;
    await pickRecent("2");
    await render(long({ sessionId: "t", model: "astra", configOptions: [medium] }));
    expect(calls).toEqual(["model astra"]);
    // An effort picked by hand while a combo waits wins: the combo's effort never follows.
    await render(long({ model: "sol", configOptions: [medium] }));
    calls.length = 0;
    await pickRecent("2");
    // Astra arrives offering Low and Medium, not yet High; the user slides to Low.
    const low = { value: "low", name: "Low" };
    await render(long({ model: "astra", configOptions: [{ ...medium, options: [low, effort.options[0]!] }] }));
    await slide(await openReasoning(), "0");
    await key(button("Model")!, "Escape");
    await render(
      long({
        model: "astra",
        configOptions: [{ ...effort, currentValue: "low", options: [low, ...effort.options] }],
      }),
    );
    expect(calls).toEqual(["model astra", "effort reasoning_effort low"]);
    // A combo for the current model drops one still waiting for another model.
    await render(long({ model: "sol", configOptions: [medium] }));
    calls.length = 0;
    await pickRecent("2");
    await pickRecent("1");
    await render(long({ model: "astra", configOptions: [medium] }));
    expect(calls).toEqual(["model astra"]);
  });

  test("recents persist per viewer, newest first and once each, and survive bad or blocked storage", () => {
    const globals = globalThis as Record<string, unknown>;
    const saved = globals.localStorage;
    const store = new Map<string, string>();
    globals.localStorage = {
      getItem: (name: string) => store.get(name) ?? null,
      setItem: (name: string, value: string) => store.set(name, value),
    };
    try {
      let list = rememberCombo(loadRecents(), { harness: "codex", model: "astra", effort: "high" });
      list = rememberCombo(list, { harness: "codex", model: "sol" });
      list = rememberCombo(list, { harness: "codex", model: "astra", effort: "high" });
      expect(loadRecents()).toEqual([
        { harness: "codex", model: "astra", effort: "high" },
        { harness: "codex", model: "sol" },
      ]);
      store.set("cmux.acpmux.recentModels", "{not json");
      expect(loadRecents()).toEqual([]);
      store.set("cmux.acpmux.recentModels", JSON.stringify([{ harness: "codex" }, { harness: "codex", model: "sol" }]));
      expect(loadRecents()).toEqual([{ harness: "codex", model: "sol" }]);
      globals.localStorage = {
        getItem: () => {
          throw new Error("blocked");
        },
        setItem: () => {
          throw new Error("blocked");
        },
      };
      expect(loadRecents()).toEqual([]);
      expect(rememberCombo([], { harness: "codex", model: "sol" })).toEqual([{ harness: "codex", model: "sol" }]);
      // Another pane's newer combo, already stored, survives this pane's older list.
      globals.localStorage = {
        getItem: (name: string) => store.get(name) ?? null,
        setItem: (name: string, value: string) => store.set(name, value),
      };
      store.set("cmux.acpmux.recentModels", JSON.stringify([{ harness: "codex", model: "luna" }]));
      rememberCombo([{ harness: "codex", model: "sol" }], { harness: "codex", model: "astra" });
      expect(loadRecents().map((combo) => combo.model)).toEqual(["astra", "luna", "sol"]);
    } finally {
      globals.localStorage = saved;
    }
  });

  test("a model the catalog doesn't list still shows by the id the agent reported", async () => {
    await render(snapshot({ model: "claude-opus-5-5" }));
    expect(button("Model")!.textContent).toBe("claude-opus-5-5");
  });

  describe("an agent's own default model and reasoning", () => {
    const claude = (summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>>): AcpmuxSnapshot => ({
      ...snapshot(),
      catalog: [
        {
          id: "claude",
          name: "Claude Code",
          models: [
            { id: "default", name: "Default (Claude Code's choice)" },
            { id: "claude-opus-5-5", name: "Opus 5.5" },
            { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
          ],
        },
      ],
      summary: { sessionId: "s", harness: "claude", model: "default", ...summary },
    });
    const defaultEffort = {
      id: "effort",
      category: "thought_level",
      currentValue: "default",
      options: [
        { value: "default", name: "Default (model's choice)" },
        { value: "low", name: "Low" },
        { value: "high", name: "High" },
      ],
    };
    const resolvedTo = (model: string) => ({
      id: "model",
      category: "model",
      currentValue: model,
      options: [
        { value: "default", name: "Default (Claude Code's choice)" },
        { value: "claude-opus-5-5", name: "Opus 5.5" },
      ],
    });
    const store = new Map<string, string>();
    const savedStorage = globals.localStorage;
    beforeEach(() => {
      store.clear();
      globals.localStorage = {
        getItem: (name: string) => store.get(name) ?? null,
        setItem: (name: string, value: string) => void store.set(name, value),
      };
    });
    afterEach(() => {
      globals.localStorage = savedStorage;
    });

    test('the chips name the model the default runs and never the agent\'s "choice" phrasing', async () => {
      await render(claude({ configOptions: [resolvedTo("claude-opus-5-5"), defaultEffort] }));
      // The default effort adds nothing after the model.
      expect(button("Model")!.textContent).toBe("Opus 5.5");
      expect(button("Effort")).toBeNull();
      await act(async () => button("Model")!.click());
      const menu = doc.querySelector(".acpmux-mp[role=menu]")!;
      expect(menu.textContent).not.toMatch(/choice/i);
      // One row for the default, named for its model with a "Default" hint, in place of a
      // "Claude Code" provider; the reasoning row says "Default" once.
      expect(rowLabels()).not.toContain("Claude Code");
      const fallback = [...menu.querySelectorAll(".acpmux-mp-row")].find(
        (row) => row.getAttribute("aria-checked") === "true",
      )!;
      expect(fallback.querySelector(".acpmux-menu-label")!.textContent).toBe("Opus 5.5");
      expect(fallback.textContent).toContain("Default");
      const reasoning = [...menu.querySelectorAll(".acpmux-mp-row")].find(
        (row) => row.querySelector(".acpmux-menu-label")?.textContent === "Reasoning",
      )!;
      expect(reasoning.textContent).toContain("Default");
      expect(doc.body.textContent).not.toMatch(/choice/i);
    });

    test('before the agent starts, the default names the model it last resolved to, else "Default"', async () => {
      await render(claude({ configOptions: [defaultEffort] }));
      expect(button("Model")!.textContent).toBe("Default");
      await render(claude({ configOptions: [resolvedTo("claude-opus-5-5"), defaultEffort] }));
      await render(claude({ sessionId: "next", configOptions: [defaultEffort] }));
      expect(button("Model")!.textContent).toBe("Opus 5.5");
    });

    test("a pick of the default not yet confirmed, or a harness still starting, names and saves no model", async () => {
      // Picked from Opus: the agent's option still names Opus until the pick lands.
      await render(
        claude({ confirmedModel: "claude-opus-5-5", configOptions: [resolvedTo("claude-opus-5-5"), defaultEffort] }),
      );
      expect(button("Model")!.textContent).toBe("Default");
      await render(claude({ configOptions: [resolvedTo("default"), defaultEffort] }));
      expect(button("Model")!.textContent).toBe("Default");
      // Starting, the composer draws the last Claude session's options, here on Sonnet.
      await render({
        ...claude({ configOptions: [resolvedTo("claude-sonnet-5-5"), defaultEffort] }),
        switching: { harness: "claude", name: "Claude Code", phase: "starting" },
      });
      expect(button("Model")!.textContent).toBe("Default");
      expect(store.get("cmux.acpmux.resolvedDefaults")).toBeUndefined();
    });

    test("a recent of the default model stays offered, and typing finds the default row", async () => {
      store.set(
        "cmux.acpmux.recentModels",
        JSON.stringify([{ harness: "claude", model: "default", effort: "high", effortName: "High" }]),
      );
      await render(claude({ model: "claude-sonnet-5-5", configOptions: [defaultEffort] }));
      await act(async () => button("Model")!.click());
      const recent = [...doc.querySelectorAll(".acpmux-mp-row")].find((row) => row.textContent?.includes("High"));
      expect(recent?.querySelector(".acpmux-menu-label")!.textContent).toBe("Default");
      for (const char of "defa") await key(button("Model")!, char);
      expect(rowLabels()).toContain("Default");
    });

    test("a model picked by name keeps its name; a recent at the default effort shows no effort", async () => {
      await render(claude({ model: "claude-sonnet-5-5", configOptions: [defaultEffort] }));
      expect(button("Model")!.textContent).toBe("Sonnet 5.5");
      await settle();
      await act(async () => button("Model")!.click());
      const recent = doc.querySelector(".acpmux-mp-row[aria-checked=true]")!;
      expect(recent.textContent).not.toMatch(/default|choice/i);
    });
  });

  test("automation opens a menu by its label, through the click path, with no pointer event", async () => {
    await render(snapshot({ configOptions: [effort] }));
    expect(pickerLabels().sort()).toEqual(["Context window", "Effort", "Model"]);
    expect(openPicker("Approvals")).toBe(false);
    let opened = false;
    await act(async () => {
      opened = openPicker("Model");
    });
    expect(opened).toBe(true);
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    // The current model shows checked under its family.
    expect(rowLabels()).toContain("6 Astra *");
    // Keys reach the menu as after a click: the chip has focus and names the highlighted row.
    expect(doc.activeElement).toBe(button("Model"));
    expect(doc.getElementById(button("Model")!.getAttribute("aria-activedescendant")!)).not.toBeNull();
    for (const char of "sol") await key(button("Model")!, char);
    await key(button("Model")!, "Enter");
    expect(calls).toEqual(["model sol"]);
    // Opening an open menu keeps it open rather than toggling it shut.
    await act(async () => {
      openPicker("Model");
    });
    await act(async () => {
      openPicker("Model");
    });
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    expect(doc.activeElement).toBe(button("Model"));
    expect(doc.querySelector('button[data-menu="Model"]')).toBe(button("Model"));
    // "Effort" opens the same menu, which holds the reasoning slider.
    await key(button("Model")!, "Escape");
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("false");
    await act(async () => {
      openPicker("Effort");
    });
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    expect(doc.querySelector('button[data-menu="Effort"]')).toBeNull();
  });

  test("opening a menu by its label takes focus off the prompt first, as a click does", async () => {
    await render(snapshot());
    const outside = doc.createElement("textarea");
    doc.body.append(outside);
    let blurred = false;
    outside.addEventListener("blur", () => {
      blurred = true;
    });
    outside.focus();
    await act(async () => {
      openPicker("Model");
    });
    expect(blurred).toBe(true);
    expect(doc.activeElement).toBe(button("Model"));
    outside.remove();
  });

  test("an unmounted menu is no longer openable", async () => {
    await render(snapshot());
    expect(pickerLabels()).toContain("Model");
    await act(async () => root.unmount());
    expect(pickerLabels()).toEqual([]);
    expect(openPicker("Model")).toBe(false);
    root = createRoot(doc.getElementById("root")!);
  });

  test("the menus close when the window loses focus", async () => {
    await render(snapshot({ modes }));
    await act(async () => button("Model")!.click());
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.Event("blur"));
    });
    expect(doc.querySelector(".acpmux-mp")).toBeNull();
    await act(async () => button("Mode")!.click());
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.Event("blur"));
    });
    expect(doc.querySelector("[role=listbox]")).toBeNull();
  });

  // The Mode and Model menus keep the focus on their chip while open and close when it leaves, so
  // their own Escape handlers always get the key; the Effort popover moves it to its slider.
  test("Escape closes the Effort popover wherever the focus is in the page", async () => {
    // Without a model list the effort keeps a chip and popover of its own.
    await render({ ...snapshot({ configOptions: [effort] }), catalog: [] });
    await act(async () => button("Effort")!.click());
    expect(doc.querySelector(".acpmux-effort-pop")).not.toBeNull();
    // Focus left the slider (a click on the popover's title, or on the page around it).
    await act(async () => (doc.activeElement as HTMLElement | null)?.blur());
    expect(doc.activeElement).toBe(doc.body);
    await key(doc.body, "Escape");
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(doc.activeElement).toBe(button("Effort"));
    expect(calls).toEqual([]);
  });

  test("a click outside closes the Effort popover without picking", async () => {
    await render({ ...snapshot({ configOptions: [effort] }), catalog: [] });
    await act(async () => button("Effort")!.click());
    expect(doc.querySelector(".acpmux-effort-pop")).not.toBeNull();
    await act(async () => {
      doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    });
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(calls).toEqual([]);
  });

  test("a single-section menu is a group named for the control", async () => {
    await render(snapshot({ modes: { ...modes, availableModes: [modes.availableModes[0]!] } }));
    await act(async () => button("Mode")!.click());
    const groups = [...doc.querySelectorAll("[role=listbox] > [role=group]")];
    expect(groups.map((group) => group.getAttribute("aria-label"))).toEqual(["Mode"]);
  });

  test("a click outside closes the menus without picking", async () => {
    await render(snapshot({ modes }));
    for (const [label, menu] of [
      ["Model", ".acpmux-mp"],
      ["Mode", "[role=listbox]"],
    ] as const) {
      await act(async () => button(label)!.click());
      expect(doc.querySelector(menu)).not.toBeNull();
      await act(async () => {
        doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
      });
      expect(doc.querySelector(menu)).toBeNull();
    }
    expect(calls).toEqual([]);
  });

  test("the mode chip shows the current mode, with descriptions in its menu and the warning color for full access", async () => {
    await render(snapshot({ modes }));
    expect(button("Mode")!.textContent).toBe("Ask for approval");
    expect(doc.querySelector(".acpmux-mode.acpmux-unrestricted")).toBeNull();
    await act(async () => button("Mode")!.click());
    expect([...doc.querySelectorAll(".acpmux-menu-description")].map((node) => node.textContent)).toEqual([
      "Always ask",
      "Unrestricted",
    ]);
    expect(doc.querySelector(".acpmux-menu-item.acpmux-unrestricted")!.textContent).toBe("Full accessUnrestricted");
    await render(snapshot({ modes: { ...modes, currentModeId: "bypassPermissions" } }));
    expect(doc.querySelector(".acpmux-mode.acpmux-unrestricted")).not.toBeNull();
    expect(unrestricted("default")).toBe(false);
  });

  test("Plan is a toggle apart from the permission chip, and leaving it restores the permission mode", async () => {
    const withPlan = {
      ...modes,
      availableModes: [...modes.availableModes, { id: "plan", name: "Plan" }],
    };
    await render(snapshot({ modes: withPlan }));
    const plan = () => doc.querySelector<HTMLButtonElement>(".acpmux-plan")!;
    expect(plan().textContent).toBe("Build");
    expect(plan().getAttribute("aria-pressed")).toBe("false");
    await act(async () => button("Mode")!.click());
    expect(options()).toEqual(["Ask for approvalAlways ask *", "Full accessUnrestricted"]);
    await act(async () => button("Mode")!.click());
    await act(async () => plan().click());
    expect(calls).toEqual(["mode plan"]);
    await render(snapshot({ modes: { ...withPlan, currentModeId: "plan" } }));
    expect(plan().textContent).toBe("Plan");
    expect(plan().getAttribute("aria-pressed")).toBe("true");
    expect(button("Mode")!.textContent).toBe("Ask for approval");
    await act(async () => plan().click());
    expect(calls).toEqual(["mode plan", "mode ask"]);
    // Another session opened in Plan doesn't inherit this one's mode: leaving goes to its first permission mode.
    await render(snapshot({ modes: { ...withPlan, currentModeId: "bypassPermissions" } }));
    await render(snapshot({ sessionId: "t", modes: { ...withPlan, currentModeId: "plan" } }));
    await act(async () => plan().click());
    expect(calls.at(-1)).toBe("mode ask");
    expect(isPlan("default")).toBe(false);
    expect(isPlan("planner")).toBe(false);
    expect(isPlan("claude_plan")).toBe(true);
  });

  test("the context ring shows the share of the window used, and warns near full", async () => {
    await render(snapshot({ usage: { used: 33551, size: 200000 } }));
    const ring = () => doc.querySelector<HTMLButtonElement>("button.acpmux-context-ring")!;
    const full = () => ring().closest(".acpmux-context")!.classList.contains("acpmux-context-full");
    expect(ring().getAttribute("aria-label")).toBe("17% of context used");
    expect(full()).toBe(false);
    await render(snapshot({ usage: { used: 180000, size: 200000 } }));
    expect(full()).toBe(true);
    // An empty window draws only the track, no dot from the round cap.
    await render(snapshot({ usage: { used: 0, size: 200000 } }));
    expect(ring().querySelectorAll("circle").length).toBe(1);
    // A live chat keeps the ring before its first usage update; no chat has none.
    await render(snapshot());
    expect(ring().querySelectorAll("circle").length).toBe(1);
    await render(snapshot({ sessionId: undefined }));
    expect(doc.querySelector(".acpmux-context-ring")).toBeNull();
  });

  test("a click on the context ring opens the usage details and Compact", async () => {
    let compacted = 0;
    const withCompact = (summary: Parameters<typeof snapshot>[0], isWorking = false) => ({
      ...snapshot(summary, isWorking),
      commands: [{ name: "compact", description: "Compact the conversation" }],
    });
    const onCompact = () => void (compacted += 1);
    await render(withCompact({ usage: { used: 34000, size: 200000 } }), { onCompact });
    const ring = doc.querySelector<HTMLButtonElement>("button.acpmux-context-ring")!;
    const pop = () => doc.querySelector(".acpmux-context-pop");
    expect(pop()).toBeNull();
    await act(async () => ring.click());
    expect(ring.getAttribute("aria-expanded")).toBe("true");
    expect(pop()!.closest("[role=dialog]")).not.toBeNull();
    expect(pop()!.querySelector(".acpmux-context-percent")!.textContent).toBe("17% used");
    expect(pop()!.querySelector(".acpmux-context-tokens")!.textContent).toBe("34K of 200K tokens");
    // A second click closes it; so does Escape.
    await act(async () => ring.click());
    expect(pop()).toBeNull();
    // A mouse press on the open ring is also the popover's outside press. In WebKit the
    // popover's dismissal settles before the ring's click handler runs, so the click finds it
    // closed: that click must not open it again.
    await act(async () => ring.click());
    await act(async () => ring.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true })));
    await key(ring, "Escape");
    await act(async () => ring.click());
    expect(pop()).toBeNull();
    expect(ring.getAttribute("aria-expanded")).toBe("false");
    await act(async () => ring.click());
    await key(ring, "Escape");
    expect(pop()).toBeNull();
    // Compact runs the agent's command and closes the details.
    await act(async () => ring.click());
    await act(async () => pop()!.querySelector<HTMLButtonElement>(".acpmux-context-compact")!.click());
    expect(compacted).toBe(1);
    expect(pop()).toBeNull();
    // Without the agent's compact command there is no Compact; before any usage there are no token counts.
    await render(snapshot({}), { onCompact });
    await act(async () => doc.querySelector<HTMLButtonElement>("button.acpmux-context-ring")!.click());
    expect(pop()!.querySelector(".acpmux-context-compact")).toBeNull();
    expect(pop()!.querySelector(".acpmux-context-percent")!.textContent).toBe("0% used");
    expect(pop()!.querySelector(".acpmux-context-tokens")).toBeNull();
  });
});

describe("acpmux composer send button", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: string[];
  let stops: number;
  const textarea = () => promptField(doc);
  const send = () => doc.querySelector(".acpmux-send")!;
  const render = async (value: AcpmuxSnapshot) => {
    await act(async () =>
      root.render(
        createElement(Composer, {
          snapshot: value,
          chips: () => null,
          onSend: (text: string) => {
            sent.push(text);
          },
          onStop: () => {
            stops += 1;
          },
        }),
      ),
    );
    await ready();
  };
  const key = async (name: string, init: KeyboardEventInit = {}) =>
    act(async () => {
      textarea().dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: name,
          bubbles: true,
          cancelable: true,
          ...init,
        }),
      );
    });

  beforeEach(() => {
    sent = [];
    stops = 0;
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("Enter sends the prompt, Shift+Enter and an input method's Enter do not", async () => {
    await render(snapshot());
    await act(async () => typeInto(textarea(), "hello"));
    await key("Enter", { shiftKey: true });
    await key("Enter", { isComposing: true });
    expect(sent).toEqual([]);
    await key("Enter");
    expect(sent).toEqual(["hello"]);
    expect(textarea().value).toBe("");
    await key("Enter");
    expect(sent).toEqual(["hello"]);
  });

  test("Send is ready only with a prompt, and becomes Stop while a turn runs with an empty prompt", async () => {
    await render(snapshot());
    expect(send().getAttribute("aria-label")).toBe("Send");
    expect(send().classList.contains("acpmux-send-ready")).toBe(false);
    await act(async () => typeInto(textarea(), "next"));
    expect(send().classList.contains("acpmux-send-ready")).toBe(true);
    await render(snapshot({}, true));
    // A prompt typed during a turn still sends (the agent queues it).
    expect(send().getAttribute("aria-label")).toBe("Send");
    await act(async () => typeInto(textarea(), ""));
    expect(send().getAttribute("aria-label")).toBe("Stop");
    await act(async () => (send() as HTMLButtonElement).click());
    expect(stops).toBe(1);
  });

  test("keyboard focus on Send moves to Stop when the turn starts", async () => {
    await render(snapshot());
    await act(async () => typeInto(textarea(), "go"));
    (send() as HTMLButtonElement).focus();
    await act(async () => {
      doc.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    });
    await render(snapshot({}, true));
    expect(send().getAttribute("aria-label")).toBe("Stop");
    expect(doc.activeElement).toBe(send());
  });

  test("Stop ignores a click that lands right after a send, such as a double-click's second", async () => {
    await render(snapshot());
    await act(async () => typeInto(textarea(), "go"));
    await act(async () => {
      doc.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    });
    await render(snapshot({}, true));
    expect(send().getAttribute("aria-label")).toBe("Stop");
    await act(async () => (send() as HTMLButtonElement).click());
    expect(sent).toEqual(["go"]);
    expect(stops).toBe(0);
  });
});

describe("acpmux composer context", () => {
  test("the context row uses plain location labels and locks after a turn", async () => {
    const root = createRoot(doc.getElementById("root")!);
    const render = async (
      summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>>,
      rows: AcpmuxSnapshot["rows"] = [],
    ) => {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: { ...snapshot(summary), rows },
            chips: () => null,
            onSend: () => {},
            onStop: () => {},
          }),
        ),
      );
      await ready();
    };
    try {
      await render({ cwd: "/Users/me/code/cmux", host: "hearty-beige-elk", hostKind: "cloud" });
      expect(doc.querySelectorAll(".acpmux-context-chip")).toHaveLength(0);
      expect([...doc.querySelectorAll(".acpmux-location-readonly")].map((node) => node.textContent)).toEqual([
        "hearty-beige-elk",
        "cmux",
      ]);
      await render({ cwd: "/Users/me/code/cmux", host: "hearty-beige-elk", hostKind: "cloud" }, [
        { id: "u", version: 1, at: 0, kind: "user", text: "hello" },
      ]);
      expect(doc.querySelector(".acpmux-composer-context")?.getAttribute("data-readonly")).toBe("true");
      expect(doc.querySelectorAll(".acpmux-location-button")).toHaveLength(0);
    } finally {
      await act(async () => root.unmount());
    }
  });
});

describe("acpmux composer queue", () => {
  test("queued prompts list above the bar in order, and the list goes away when empty", async () => {
    const root = createRoot(doc.getElementById("root")!);
    const render = async (queue: AcpmuxSnapshot["queue"]) => {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: { ...snapshot({}, true), queue },
            chips: () => null,
            onSend: () => {},
            onStop: () => {},
          }),
        ),
      );
      await ready();
    };
    try {
      await render([
        { id: "p1", prompt: "first" },
        { id: "p2", prompt: "second\nline" },
      ]);
      const list = doc.querySelector("ol.acpmux-composer-queue")!;
      expect(list.getAttribute("aria-label")).toBe("Queued prompts");
      expect([...list.querySelectorAll(".acpmux-queued-text")].map((node) => node.textContent)).toEqual([
        "first",
        "second\nline",
      ]);
      expect(list.nextElementSibling!.classList.contains("acpmux-composer-context")).toBe(true);
      // The slash menu anchors to the field, so the queue never pushes it up.
      await act(async () => typeInto(promptField(doc), "/"));
      expect(doc.querySelector(".acpmux-composer-box > .acpmux-slash-menu")).not.toBeNull();
      await act(async () => typeInto(promptField(doc), ""));
      await render([]);
      expect(doc.querySelector(".acpmux-composer-queue")).toBeNull();
    } finally {
      await act(async () => root.unmount());
    }
  });

  test("with a session's place shown, the queue sits on the context tray and the tray on the box", async () => {
    const root = createRoot(doc.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: {
              ...snapshot({ cwd: "/Users/me/code/cmux", host: "This Mac", hostKind: "local", branch: "main" }, true),
              queue: [{ id: "p1", prompt: "next" }],
            },
            chips: () => null,
            onSend: () => {},
            onStop: () => {},
          }),
        ),
      );
      const queue = doc.querySelector("ol.acpmux-composer-queue")!;
      const tray = queue.nextElementSibling!;
      expect(tray.classList.contains("acpmux-composer-context")).toBe(true);
      expect(tray.nextElementSibling!.classList.contains("acpmux-composer-box")).toBe(true);
    } finally {
      await act(async () => root.unmount());
    }
  });
});
