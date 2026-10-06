import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

// hqacp-v4: Escape closed a composer menu and left the focus on its button, so the next typed keys
// went to the menu. Escape now closes the menu and returns the focus to the prompt, as a chat
// composer does; a click outside closes it and moves no focus.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "requestAnimationFrame", "cancelAnimationFrame"];
const saved = Object.fromEntries([...keys, "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
const { proseMirrorGlobals, promptField } = await import("./promptFieldTesting");
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
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
const { ComposerPickers } = await import("./ComposerPickers");
const { useComposerKeyboard } = await import("./composerFocus");

const doc = dom.window.document;
const modes = {
  currentModeId: "ask",
  availableModes: [
    { id: "ask", name: "Ask for approval" },
    { id: "bypassPermissions", name: "Full access" },
  ],
};
const effort = {
  id: "reasoning_effort",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};
const snapshot = (withModels: boolean): AcpmuxSnapshot => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: withModels
    ? [
        {
          id: "codex",
          name: "Codex",
          models: [
            { id: "astra", name: "6 Astra" },
            { id: "sol", name: "6.1 Sol" },
          ],
        },
      ]
    : [],
  summary: {
    sessionId: "s",
    harness: "codex",
    model: "astra",
    modes,
    configOptions: [effort],
    cwd: "/Users/me/code/cmux",
    host: "This Mac",
    hostKind: "local",
  },
});
const folders = [
  { cwd: "/Users/me/code/cmux", label: "cmux" },
  { cwd: "/Users/me/Projects/relay", label: "relay" },
];

/// The pane as App mounts it: the composer's claim on the keyboard, and the composer with its chips.
function Pane({ value }: { value: AcpmuxSnapshot }) {
  useComposerKeyboard(() => {
    const prompt = doc.querySelector<HTMLElement>(".acpmux-composer .acpmux-md");
    if (!prompt) return false;
    prompt.focus();
    return true;
  });
  return createElement(Composer, {
    snapshot: value,
    chips: ({ snapshot: shown }: { snapshot: AcpmuxSnapshot }) =>
      createElement(ComposerPickers, {
        snapshot: shown,
        measurePickerRoom: () => 600,
        onModel: () => {},
        onMode: () => {},
        onEffort: () => {},
      }),
    projectChoices: folders,
    onBrowseProject: () => {},
    onProject: () => {},
    onSend: () => {},
    onStop: () => {},
  });
}

describe("Escape in a composer menu", () => {
  let root: ReturnType<typeof createRoot>;
  const button = (label: string) =>
    doc.querySelector<HTMLButtonElement>(`[aria-label="${label}"].acpmux-picker-button`)!;
  const prompt = () => promptField(doc).element;
  /// Escape as a keyboard sends it: down on the focused element, then up.
  const escape = async () => {
    const target = doc.activeElement ?? doc.body;
    await act(async () => {
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
    await act(async () => {
      (doc.activeElement ?? doc.body).dispatchEvent(
        new dom.window.KeyboardEvent("keyup", { key: "Escape", bubbles: true, cancelable: true }),
      );
    });
  };
  const render = async (withModels: boolean) => {
    await act(async () => root.render(createElement(Pane, { value: snapshot(withModels) })));
    await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
  };

  beforeEach(() => {
    root = createRoot(doc.getElementById("root")!);
  });
  afterEach(async () => {
    await act(async () => root.unmount());
  });

  test("closes the Mode menu and puts the focus in the prompt", async () => {
    await render(true);
    const mode = button("Mode");
    await act(async () => mode.click());
    expect(mode.getAttribute("aria-expanded")).toBe("true");
    expect(doc.activeElement).toBe(mode);
    await escape();
    expect(mode.getAttribute("aria-expanded")).toBe("false");
    expect(doc.activeElement).toBe(prompt());
  });

  test("closes the Model menu and puts the focus in the prompt", async () => {
    await render(true);
    const model = button("Model");
    await act(async () => model.click());
    expect(model.getAttribute("aria-expanded")).toBe("true");
    await escape();
    expect(model.getAttribute("aria-expanded")).toBe("false");
    expect(doc.activeElement).toBe(prompt());
  });

  test("closes the Effort popover from its slider and puts the focus in the prompt", async () => {
    await render(false);
    await act(async () => button("Effort").click());
    expect(doc.querySelector(".acpmux-effort-pop")).not.toBeNull();
    await escape();
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
    expect(doc.activeElement).toBe(prompt());
  });

  test("closes the folder menu (a Base UI menu) and puts the focus in the prompt", async () => {
    await render(true);
    const folder = doc.querySelector<HTMLButtonElement>(".acpmux-location-picker .acpmux-location-button")!;
    await act(async () => folder.click());
    expect(doc.querySelector(".acpmux-location-menu")).not.toBeNull();
    await act(async () => doc.querySelector<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')!.focus());
    await escape();
    await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
    expect(doc.querySelector(".acpmux-location-menu")).toBeNull();
    expect(doc.activeElement).toBe(prompt());
  });

  test("a click outside closes the menu and moves no focus to the prompt", async () => {
    await render(true);
    const mode = button("Mode");
    await act(async () => mode.click());
    await act(async () => {
      doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, cancelable: true }));
    });
    expect(mode.getAttribute("aria-expanded")).toBe("false");
    expect(doc.activeElement).not.toBe(prompt());
  });

  test("Escape in the prompt itself leaves the focus where it is", async () => {
    await render(true);
    await act(async () => prompt().focus());
    await escape();
    expect(doc.activeElement).toBe(prompt());
  });
});
