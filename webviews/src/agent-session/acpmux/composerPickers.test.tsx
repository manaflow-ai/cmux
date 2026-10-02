import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "requestAnimationFrame", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { ComposerPickers, isPlan, loadRecents, rememberCombo, unrestricted } = await import("./ComposerPickers");
const { openPicker, pickerLabels } = await import("./pickerOpeners");
const { createAcpmuxDebug } = await import("./debug");

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

/// Types into the prompt through React's change handler (see composer.test.tsx for why).
function typeInto(node: HTMLTextAreaElement, value: string) {
  node.value = value;
  node.setSelectionRange(value.length, value.length);
  const props = (node as unknown as Record<string, { onChange(event: { target: HTMLTextAreaElement }): void }>)[
    Object.keys(node).find((key) => key.startsWith("__reactProps$"))!
  ]!;
  props.onChange({ target: node });
}

describe("acpmux composer pickers", () => {
  let root: ReturnType<typeof createRoot>;
  let calls: string[];
  const render = async (value: AcpmuxSnapshot) =>
    act(async () =>
      root.render(
        createElement(ComposerPickers, {
          snapshot: value,
          settleMs: 0,
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
  const slider = () => doc.querySelector<HTMLInputElement>(".acpmux-effort-pop input[type=range]");
  // Moves the thumb as a drag or arrow key would, through React's onChange as typeInto does.
  const slide = async (to: number) =>
    act(async () => {
      const node = slider()!;
      node.value = String(to);
      const props = (node as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
        Object.keys(node).find((key) => key.startsWith("__reactProps$"))!
      ]!;
      props.onChange({ target: node });
    });
  const key = async (target: Element, name: string) =>
    act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });

  beforeEach(() => {
    calls = [];
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("the model is a dropdown with its current choice checked, and the effort a slider on its current level", async () => {
    await render(snapshot({ configOptions: [effort] }));
    expect(button("Model")!.textContent).toBe("6 Astra");
    expect(button("Effort")!.textContent).toBe("High");
    expect(button("Mode")).toBeNull();
    await act(async () => button("Model")!.click());
    expect(options()).toEqual(["6 Astra *", "6.1 Sol"]);
    await act(async () => {
      doc
        .querySelectorAll("[role=option]")[1]!
        .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    expect(calls).toEqual(["model sol"]);
    expect(doc.querySelector("[role=listbox]")).toBeNull();
    await act(async () => button("Effort")!.click());
    expect(slider()!.value).toBe("1");
    expect(slider()!.getAttribute("aria-valuetext")).toBe("High");
    expect(doc.querySelector(".acpmux-effort-name")!.textContent).toBe("High");
  });

  test("the effort slider sends a level once the key or drag ends, and Escape closes it back to the chip", async () => {
    await render(snapshot({ configOptions: [effort] }));
    await act(async () => button("Effort")!.click());
    expect(doc.activeElement).toBe(slider());
    const fill = () =>
      doc.querySelector<HTMLElement>(".acpmux-effort-track")!.style.getPropertyValue("--acpmux-effort-fill");
    expect(fill()).toBe("1");
    await slide(0);
    // The popover names the level under the thumb before it is sent.
    expect(doc.querySelector(".acpmux-effort-name")!.textContent).toBe("Medium");
    expect(calls).toEqual([]);
    // The track fills to the thumb as it moves.
    expect(fill()).toBe("0");
    await act(async () => {
      slider()!.dispatchEvent(new dom.window.KeyboardEvent("keyup", { key: "ArrowLeft", bubbles: true }));
    });
    expect(calls).toEqual(["effort reasoning_effort medium"]);
    // Escape backs out of a move not yet sent, and hands focus back to the chip.
    await slide(1);
    await key(slider()!, "Escape");
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(doc.activeElement).toBe(button("Effort"));
    expect(calls).toEqual(["effort reasoning_effort medium"]);
  });

  test("a click outside the effort popover keeps the level under the thumb, by its id", async () => {
    await render(snapshot({ configOptions: [effort] }));
    await act(async () => button("Effort")!.click());
    await slide(0);
    // A live update puts a level in front; the thumb stays on Medium, not on what is now first.
    await render(
      snapshot({ configOptions: [{ ...effort, options: [{ value: "low", name: "Low" }, ...effort.options] }] }),
    );
    expect(doc.querySelector(".acpmux-effort-name")!.textContent).toBe("Medium");
    await act(async () => {
      doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    });
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(calls).toEqual(["effort reasoning_effort medium"]);
  });

  test("automation reports each menu open, the listbox and the effort slider alike", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const debug = createAcpmuxDebug({ replaceRows: () => {}, rowCount: () => 0 });
    // openMenu waits on real frames, so React renders on its own schedule here, as in the pane.
    globals.IS_REACT_ACT_ENVIRONMENT = false;
    try {
      for (const label of ["Model", "Effort"]) {
        expect(await debug.openMenu(label)).toEqual({ opened: label, open: true });
        doc.activeElement!.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
        );
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    } finally {
      globals.IS_REACT_ACT_ENVIRONMENT = true;
    }
    expect(await debug.openMenu("Approvals")).toEqual({
      error: 'no menu labelled "Approvals"',
      menus: ["Model", "Effort"],
    });
  });

  test("the effort popover's model line opens the model menu", async () => {
    await render(snapshot({ configOptions: [effort] }));
    await act(async () => button("Effort")!.click());
    const model = doc.querySelector<HTMLButtonElement>(".acpmux-effort-model")!;
    expect(model.textContent).toBe("6 Astra");
    await act(async () => model.click());
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    expect(options()).toEqual(["6 Astra *", "6.1 Sol"]);
  });

  test("arrows and Enter pick from the menu, and Escape closes it back to the button", async () => {
    await render(snapshot({ configOptions: [effort] }));
    const model = button("Model")!;
    await key(model, "ArrowDown");
    expect(model.getAttribute("aria-expanded")).toBe("true");
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("6 Astra");
    await key(model, "ArrowUp");
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("6.1 Sol");
    await key(model, "Enter");
    expect(calls).toEqual(["model sol"]);
    await key(model, "ArrowDown");
    await key(model, "Escape");
    expect(doc.querySelector("[role=listbox]")).toBeNull();
    expect(doc.activeElement).toBe(model);
    expect(calls).toEqual(["model sol"]);
  });

  test("Space picks on keyup without the button's click reopening the menu, and a shrunk list keeps a row highlighted", async () => {
    const withModels = (models: { id: string; name: string }[]) => ({
      ...snapshot(),
      catalog: [{ id: "codex", name: "Codex", models }],
    });
    const astra = { id: "astra", name: "6 Astra" };
    const sol = { id: "sol", name: "6.1 Sol" };
    await render(withModels([astra, sol, { id: "luna", name: "6 Luna" }]));
    const level = button("Model")!;
    await key(level, "ArrowDown");
    await key(level, "ArrowUp");
    expect(doc.getElementById(level.getAttribute("aria-activedescendant")!)!.textContent).toBe("6 Luna");
    // A live update drops that option while it is highlighted.
    await render(withModels([astra, sol]));
    expect(doc.getElementById(level.getAttribute("aria-activedescendant")!)!.textContent).toBe("6.1 Sol");
    await key(level, " ");
    expect(level.getAttribute("aria-expanded")).toBe("true");
    const up = new dom.window.KeyboardEvent("keyup", { key: " ", bubbles: true, cancelable: true });
    await act(async () => {
      level.dispatchEvent(up);
    });
    expect(up.defaultPrevented).toBe(true);
    expect(calls).toEqual(["model sol"]);
    expect(level.getAttribute("aria-expanded")).toBe("false");
  });

  test("a long catalog offers recent model and effort combos first, and folds the rest under a searchable More models", async () => {
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
    const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 5)));
    // The session runs Astra on High, then Sol on Medium: both become recents.
    await render(long({ configOptions: [effort] }));
    await settle();
    await act(async () => button("Model")!.click());
    expect(options()).toEqual(["6 Astra *", "6.1 Sol", "6 Luna", "6 Mini", "6 Nano"]);
    await act(async () => button("Model")!.click());
    // The switch passes through Sol on the old effort before the new one lands; only the settled combo counts.
    await render(long({ model: "sol", configOptions: [effort] }));
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    await settle();
    const model = button("Model")!;
    await act(async () => model.click());
    expect(doc.querySelector(".acpmux-menu-header")!.textContent).toBe("Recent");
    expect(options()).toEqual(["6.1 Sol · Medium *", "6 Astra · High", "More models"]);
    // One click switches the model, then the effort once the agent reports that model offering it.
    const pickRecent = (index: number) =>
      act(async () => {
        doc
          .querySelectorAll("[role=option]")
          [index]!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
      });
    await pickRecent(1);
    expect(calls).toEqual(["model astra"]);
    await render(long({ model: "astra", configOptions: [{ ...effort, currentValue: "medium" }] }));
    expect(calls).toEqual(["model astra", "effort reasoning_effort high"]);
    // A model that doesn't offer the stored effort keeps its own.
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    await act(async () => button("Model")!.click());
    await pickRecent(1);
    await render(
      long({ model: "astra", configOptions: [{ ...effort, currentValue: "medium", options: [effort.options[0]!] }] }),
    );
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    await render(long({ model: "astra", configOptions: [{ ...effort, currentValue: "medium" }] }));
    expect(calls).toEqual(["model astra", "effort reasoning_effort high", "model astra"]);
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    // A combo still waiting when the pane switches sessions doesn't follow into the other session.
    await act(async () => button("Model")!.click());
    await pickRecent(1);
    await render(long({ sessionId: "t", model: "astra", configOptions: [{ ...effort, currentValue: "medium" }] }));
    // A plain pick through More models drops a waiting combo's effort.
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    await act(async () => button("Model")!.click());
    await pickRecent(1);
    await act(async () => button("Model")!.click());
    await pickRecent(2);
    await act(async () => {
      [...doc.querySelectorAll("[role=option]")]
        .find((option) => option.textContent === "6 Astra")!
        .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    await render(long({ model: "astra", configOptions: [{ ...effort, currentValue: "medium" }] }));
    expect(calls.filter((call) => call.startsWith("effort"))).toEqual(["effort reasoning_effort high"]);
    await render(long({ model: "sol", configOptions: [{ ...effort, currentValue: "medium" }] }));
    calls.length = 0;
    // More models opens the full list in place; typing filters it and Enter picks.
    await key(model, "ArrowDown");
    await key(model, "ArrowUp");
    await key(model, "Enter");
    expect(model.getAttribute("aria-expanded")).toBe("true");
    expect(options()).toEqual([
      "6.1 Sol · Medium *",
      "6 Astra · High",
      "6 Astra",
      "6.1 Sol *",
      "6 Luna",
      "6 Mini",
      "6 Nano",
    ]);
    expect(doc.querySelector(".acpmux-menu-search")!.textContent).toBe("Type to search models");
    await key(model, "l");
    await key(model, "u");
    expect(doc.querySelector(".acpmux-menu-search")!.textContent).toBe("lu");
    expect(options()).toEqual(["6 Luna"]);
    await key(model, "Backspace");
    expect(options()).toEqual(["6.1 Sol · Medium *", "6.1 Sol *", "6 Luna"]);
    await key(model, "u");
    await key(model, "ArrowUp");
    await key(model, "Enter");
    expect(calls.at(-1)).toBe("model luna");
    // A query that matches nothing leaves no highlight; Backspace brings the rows and the highlight back.
    await act(async () => model.click());
    await pickRecent(2);
    expect(doc.querySelector("[role=listbox] .acpmux-menu-search")).toBeNull();
    await key(model, "z");
    await key(model, "z");
    expect(options()).toEqual([]);
    await key(model, "ArrowDown");
    expect(model.getAttribute("aria-activedescendant")).toBeNull();
    await key(model, "Backspace");
    await key(model, "Backspace");
    await key(model, "ArrowDown");
    expect(doc.getElementById(model.getAttribute("aria-activedescendant")!)!.textContent).toBe("6 Astra · High");
    await act(async () => model.click());
    // Closing folds the list again.
    await act(async () => model.click());
    expect(options()).toEqual(["6.1 Sol · Medium *", "6 Astra · High", "More models"]);
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
    } finally {
      globals.localStorage = saved;
    }
  });

  test("a model the catalog doesn't list still shows by the id the agent reported", async () => {
    await render(snapshot({ model: "claude-opus-5-5" }));
    expect(button("Model")!.textContent).toBe("claude-opus-5-5");
  });

  test("automation opens a menu by its label, through the click path, with no pointer event", async () => {
    await render(snapshot({ configOptions: [effort] }));
    expect(pickerLabels().sort()).toEqual(["Effort", "Model"]);
    expect(openPicker("Approvals")).toBe(false);
    let opened = false;
    await act(async () => {
      opened = openPicker("Model");
    });
    expect(opened).toBe(true);
    expect(button("Model")!.getAttribute("aria-expanded")).toBe("true");
    expect(options()).toEqual(["6 Astra *", "6.1 Sol"]);
    // Keys reach the menu as after a click: the button has focus.
    expect(doc.activeElement).toBe(button("Model"));
    await key(button("Model")!, "ArrowDown");
    await key(button("Model")!, "Enter");
    expect(calls).toEqual(["model sol"]);
    // Opening an open menu keeps it open rather than toggling it shut; the effort opens its slider.
    await act(async () => {
      openPicker("Effort");
      openPicker("Effort");
    });
    expect(button("Effort")!.getAttribute("aria-expanded")).toBe("true");
    expect(doc.activeElement).toBe(slider());
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

  test("the menu closes when the window loses focus", async () => {
    await render(snapshot());
    await act(async () => button("Model")!.click());
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.Event("blur"));
    });
    expect(doc.querySelector("[role=listbox]")).toBeNull();
  });

  test("a single-section menu is a group named for the control", async () => {
    await render(snapshot());
    await act(async () => button("Model")!.click());
    const groups = [...doc.querySelectorAll("[role=listbox] > [role=group]")];
    expect(groups.map((group) => group.getAttribute("aria-label"))).toEqual(["Model"]);
  });

  test("a click outside closes the menu without picking", async () => {
    await render(snapshot());
    await act(async () => button("Model")!.click());
    expect(doc.querySelector("[role=listbox]")).not.toBeNull();
    await act(async () => {
      doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    });
    expect(doc.querySelector("[role=listbox]")).toBeNull();
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
    const withPlan = { ...modes, availableModes: [...modes.availableModes, { id: "plan", name: "Plan" }] };
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
    const ring = () => doc.querySelector(".acpmux-context-ring")!;
    expect(ring().getAttribute("aria-label")).toBe("17% of context used");
    expect(ring().classList.contains("acpmux-context-full")).toBe(false);
    await render(snapshot({ usage: { used: 180000, size: 200000 } }));
    expect(ring().classList.contains("acpmux-context-full")).toBe(true);
    // An empty window draws only the track, no dot from the round cap.
    await render(snapshot({ usage: { used: 0, size: 200000 } }));
    expect(ring().querySelectorAll("circle").length).toBe(1);
    await render(snapshot());
    expect(doc.querySelector(".acpmux-context-ring")).toBeNull();
  });
});

describe("acpmux composer send button", () => {
  let root: ReturnType<typeof createRoot>;
  let sent: string[];
  let stops: number;
  const textarea = () => doc.querySelector("textarea")!;
  const send = () => doc.querySelector(".acpmux-send")!;
  const render = async (value: AcpmuxSnapshot) =>
    act(async () =>
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
  const key = async (name: string, init: KeyboardEventInit = {}) =>
    act(async () => {
      textarea().dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init }),
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
  test("the tray names the project, the machine and the branch, and the worktree switch shows whether the session has one", async () => {
    const root = createRoot(doc.getElementById("root")!);
    const render = async (summary: Partial<NonNullable<AcpmuxSnapshot["summary"]>>) =>
      act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: snapshot(summary),
            chips: () => null,
            onSend: () => {},
            onStop: () => {},
          }),
        ),
      );
    const chips = () =>
      [...doc.querySelectorAll(".acpmux-context-chip")].map(
        (chip) => `${chip.textContent}|${chip.getAttribute("title") ?? ""}`,
      );
    try {
      await render({});
      expect(doc.querySelector(".acpmux-composer-context")).toBeNull();
      await render({
        cwd: "/Users/me/code/cmux",
        host: "hearty-beige-elk",
        hostKind: "cloud",
        branch: "feat-retry-backoff",
        worktree: "/Users/me/code/cmux-retry",
      });
      expect(chips()).toEqual([
        "cmux|Project: /Users/me/code/cmux",
        "hearty-beige-elk|",
        "feat-retry-backoff|Branch: feat-retry-backoff",
      ]);
      const worktree = () => doc.querySelector(".acpmux-context-worktree")!;
      expect(worktree().classList.contains("acpmux-on")).toBe(true);
      expect(worktree().getAttribute("title")).toBe("Worktree: /Users/me/code/cmux-retry");
      expect(worktree().querySelector(".acpmux-switch")!.getAttribute("aria-label")).toBe("On");
      expect(
        doc.querySelector(".acpmux-composer-context")!.nextElementSibling!.classList.contains("acpmux-composer-box"),
      ).toBe(true);
      // The home folder is no project; a plain branch is titled as one.
      await render({ cwd: "/Users/me", host: "This Mac", hostKind: "local", branch: "main" });
      expect(chips()).toEqual(["This Mac|", "main|Branch: main"]);
      expect(worktree().classList.contains("acpmux-on")).toBe(false);
      expect(worktree().querySelector(".acpmux-switch")!.getAttribute("aria-label")).toBe("Off");
    } finally {
      await act(async () => root.unmount());
    }
  });
});
