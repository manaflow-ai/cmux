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
const { webKitPress } = await import("./popoverTriggerTesting");

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
  beforeEach(() => {
    calls = [];
    pendingSettles.clear();
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("one harness/model control keeps effort separate and opens a searchable two-column picker", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const model = button("Model")!;
    expect(model.querySelector(".acpmux-model-name")!.textContent).toBe("6 Astra");
    expect(model.querySelector(".agent-mark")?.getAttribute("data-agent")).toBe("openai");
    expect(button("Effort")!.textContent).toContain("High");
    expect(button("Mode")).toBeNull();
    const chipRow = model.closest(".acpmux-chips")!;
    const controls = [...chipRow.children];
    expect(controls.indexOf(model.closest(".acpmux-model")!)).toBeLessThan(
      controls.indexOf(doc.querySelector(".acpmux-context")!),
    );
    await act(async () => model.click());
    const menu = doc.querySelector(".acpmux-mp[role=dialog]")!;
    const astra = [...menu.querySelectorAll(".acpmux-mp-row")].find(
      (row) => row.querySelector(".acpmux-menu-label")?.textContent === "6 Astra",
    );
    expect(astra!.getAttribute("aria-checked")).toBe("true");
    const search = menu.querySelector<HTMLInputElement>("input[role=combobox]")!;
    expect(doc.activeElement).toBe(search);
    await act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "sol");
      search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    await key(search, "Enter");
    expect(calls).toEqual(["model sol"]);
    expect(doc.querySelector(".acpmux-mp")).toBeNull();
    expect(doc.querySelector(".acpmux-model-effort")).toBeNull();
  });

  test("the chip shows no effort for the agent's default level", async () => {
    await render(
      snapshot({
        configOptions: [{ ...effort, currentValue: "default", options: [{ value: "default", name: "Default" }] }],
      }),
    );
    expect(button("Model")!.textContent).toContain("6 Astra");
    expect(button("Effort")!.textContent).toContain("Reasoning");
  });

  test("the permission chip stays in the bar when Plan lives in the + menu", async () => {
    await render(snapshot({ modes: { ...modes, currentModeId: "bypassPermissions" } }), { showPlan: false });
    expect(button("Mode")!.querySelector(".acpmux-icon")).not.toBeNull();
    expect(button("Mode")!.closest(".acpmux-mode")!.classList.contains("acpmux-unrestricted")).toBe(true);
    expect(doc.querySelector(".acpmux-plan")).toBeNull();
  });

  // Quarantined (bead cx-svv2): run alone, the Mode chip (a Base UI menu) reopens on this press.
  // It passed only on state other files leaked into the shared test process.
  test.skip("pressing an open chip closes its menu, as WebKit delivers the press; it never reopens", async () => {
    await render(snapshot({ modes }));
    for (const label of ["Model", "Mode"]) {
      const chip = button(label)!;
      await webKitPress(dom.window as never, act as never, chip);
      expect(chip.getAttribute("aria-expanded")).toBe("true");
      await webKitPress(dom.window as never, act as never, chip);
      expect(chip.getAttribute("aria-expanded")).toBe("false");
    }
  });

  test("arrows and Enter pick from the menu, and Escape closes it back to the button", async () => {
    await render(snapshot({ modes }));
    const mode = button("Mode")!;
    await key(mode, "ArrowDown");
    expect(mode.getAttribute("aria-expanded")).toBe("true");
    expect(doc.querySelector("[role=menu]")!.textContent).toContain("Ask for approval");
    expect(doc.querySelector("[role=menu]")!.textContent).toContain("Full access");
    const full = [...doc.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find((row) =>
      row.textContent?.includes("Full access"),
    );
    full?.focus();
    await key(full!, "Enter");
    expect(calls).toEqual(["mode bypassPermissions"]);
    await act(async () => mode.click());
    await key(mode, "Escape");
    expect(doc.querySelector("[role=menu]")).toBeNull();
    expect(doc.activeElement).toBe(mode);
    expect(calls).toEqual(["mode bypassPermissions"]);
  });

  test("Space picks on keyup without the button's click reopening the menu, and a shrunk list keeps a row highlighted", async () => {
    const full = { ...modes, currentModeId: "bypassPermissions" };
    await render(snapshot({ modes: full }));
    const mode = button("Mode")!;
    // The highlight opens on the current mode, the last one.
    await key(mode, "ArrowDown");
    expect(
      [...doc.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find((row) =>
        row.textContent?.includes("Full access"),
      ),
    ).toBeTruthy();
    // A live update drops that option while it is highlighted.
    await render(snapshot({ modes: { ...full, availableModes: [full.availableModes[0]!] } }));
    expect(
      [...doc.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find((row) =>
        row.textContent?.includes("Ask for approval"),
      ),
    ).toBeTruthy();
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
    const menu = doc.querySelector("[role=menu]")!;
    expect(menu.textContent).toContain("Always ask");
    expect(menu.textContent).toContain("Unrestricted");
  });

  test("model rows keep a fixed order across openings and put the newest model nearest the anchor", async () => {
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
    await render(long({ configOptions: [effort] }));
    const model = button("Model")!;
    await act(async () => model.click());
    const labels = () => [...doc.querySelectorAll(".acpmux-mp-row .acpmux-menu-label")].map((row) => row.textContent);
    const first = labels();
    expect(first.at(-1)).toBe("6.1 Sol");
    expect(first).toEqual(["6 Astra", "6 Luna", "6 Mini", "6 Nano", "6.1 Sol"]);
    await act(async () => model.click());
    await render(long({ model: "sol", configOptions: [effort] }));
    await act(async () => button("Model")!.click());
    expect(labels()).toEqual(first);
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
      expect(button("Model")!.textContent).toBe("Opus 5.5");
      expect(button("Effort")!.textContent).toContain("Reasoning");
      await act(async () => button("Model")!.click());
      const menu = doc.querySelector(".acpmux-mp[role=dialog]")!;
      expect(menu.textContent).not.toMatch(/choice/i);
      const fallback = [...menu.querySelectorAll(".acpmux-mp-row")].find(
        (row) => row.getAttribute("aria-checked") === "true",
      )!;
      expect(fallback.querySelector(".acpmux-menu-label")!.textContent).toBe("Default");
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
      const defaults = [...doc.querySelectorAll(".acpmux-mp-row")].filter(
        (row) => row.querySelector(".acpmux-menu-label")?.textContent === "Default",
      );
      expect(defaults).toHaveLength(1);
      const search = doc.querySelector<HTMLInputElement>(".acpmux-mp-search input")!;
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "defa");
      await act(async () => search.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
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
    expect(rowLabels()).toContain("6 Astra *");
    const search = doc.querySelector<HTMLInputElement>(".acpmux-mp-search input")!;
    expect(doc.activeElement).toBe(search);
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "sol");
    await act(async () => search.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
    await key(search, "Enter");
    expect(calls).toEqual(["model sol"]);
    // Opening an open menu keeps it open rather than toggling it shut.
    await act(async () => {
      openPicker("Model");
    });
    await act(async () => {
      openPicker("Model");
    });
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    expect(doc.activeElement).toBe(doc.querySelector(".acpmux-mp-search input"));
    expect(doc.querySelector('button[data-menu="Model"]')).toBe(button("Model"));
    await key(doc.querySelector(".acpmux-mp-search input")!, "Escape");
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("false");
    await act(async () => {
      openPicker("Effort");
    });
    expect(button("Effort")!.getAttribute("aria-expanded")).toBe("true");
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
    expect(doc.activeElement).toBe(doc.querySelector(".acpmux-mp-search input"));
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
    const menu = doc.querySelector("[role=menu]")!;
    expect(menu.querySelectorAll("[role=menuitemradio]")).toHaveLength(1);
  });

  test("a click outside closes the menus without picking", async () => {
    await render(snapshot({ modes }));
    for (const [label, menu] of [
      ["Model", ".acpmux-mp"],
      ["Mode", "[role=menu]"],
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
    expect(button("Mode")!.textContent).not.toContain("Ask for approval");
    expect(doc.querySelector(".acpmux-mode.acpmux-unrestricted")).toBeNull();
    await act(async () => button("Mode")!.click());
    expect([...doc.querySelectorAll(".acpmux-menu-description")].map((node) => node.textContent)).toEqual([
      "Always ask",
      "Unrestricted",
    ]);
    expect(doc.querySelector(".acpmux-access-item.acpmux-unrestricted")!.textContent).toContain("Full access");
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
    expect(doc.querySelectorAll("[role=menuitemradio]")).toHaveLength(2);
    await act(async () => button("Mode")!.click());
    await act(async () => plan().click());
    expect(calls).toEqual(["mode plan"]);
    await render(snapshot({ modes: { ...withPlan, currentModeId: "plan" } }));
    expect(plan().textContent).toBe("Plan");
    expect(plan().getAttribute("aria-pressed")).toBe("true");
    expect(button("Mode")!.querySelectorAll("svg")).toHaveLength(2);
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
      await render({ cwd: "/Users/me/code/cmux", host: "hearty-beige-elk", hostKind: "cloud", branch: "main" });
      expect(doc.querySelectorAll(".acpmux-context-chip")).toHaveLength(0);
      expect([...doc.querySelectorAll(".acpmux-location-readonly")].map((node) => node.textContent)).toEqual([
        "cmux",
        "hearty-beige-elk",
      ]);
      await render({ cwd: "/Users/me/code/cmux", host: "hearty-beige-elk", hostKind: "cloud", branch: "main" }, [
        { id: "u", version: 1, at: 0, kind: "user", text: "hello" },
      ]);
      expect(doc.querySelector(".acpmux-composer-context")?.getAttribute("data-readonly")).toBe("true");
      expect(doc.querySelectorAll(".acpmux-location-button")).toHaveLength(1);
      expect(doc.querySelector('.acpmux-location-button[aria-label="Branch"]')).not.toBeNull();
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
      expect(doc.querySelector(".acpmux-composer-context")).not.toBeNull();
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

  test("with a session's place shown, the queue sits on the card and the place is the card's footer row", async () => {
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
      const box = doc.querySelector(".acpmux-composer-box")!;
      expect(box.lastElementChild!.classList.contains("acpmux-composer-context")).toBe(true);
      expect(box.previousElementSibling!.classList.contains("acpmux-composer-queue")).toBe(true);
    } finally {
      await act(async () => root.unmount());
    }
  });
});
