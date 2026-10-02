import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
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
const { Composer } = await import("./Composer");
const { ComposerPickers, isPlan, unrestricted } = await import("./ComposerPickers");

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

  test("the model is a dropdown with its current choice checked; the effort is a stepped slider", async () => {
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
    // The popover names the effort and the model over one stop per level.
    expect(doc.querySelector(".acpmux-effort-title")!.textContent).toBe("High");
    expect(doc.querySelector(".acpmux-effort-model")!.textContent).toBe("6 Astra");
    const range = doc.querySelector<HTMLInputElement>(".acpmux-effort-range")!;
    expect([range.min, range.max, range.value]).toEqual(["0", "1", "1"]);
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(range, "0");
      range.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    expect(calls).toEqual(["model sol", "effort reasoning_effort medium"]);
    // Escape closes it back to the chip.
    await key(range, "Escape");
    expect(doc.querySelector(".acpmux-effort-pop")).toBeNull();
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

  test("a model the catalog doesn't list still shows by the id the agent reported", async () => {
    await render(snapshot({ model: "claude-opus-5-5" }));
    expect(button("Model")!.textContent).toBe("claude-opus-5-5");
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

describe("acpmux composer queue", () => {
  test("queued prompts list above the bar in order, and the list goes away when empty", async () => {
    const root = createRoot(doc.getElementById("root")!);
    const render = async (queue: AcpmuxSnapshot["queue"]) =>
      act(async () =>
        root.render(
          createElement(Composer, {
            snapshot: { ...snapshot({}, true), queue },
            chips: () => null,
            onSend: () => {},
            onStop: () => {},
          }),
        ),
      );
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
      expect(list.nextElementSibling!.classList.contains("acpmux-composer-box")).toBe(true);
      // The slash menu anchors to the field, so the queue never pushes it up.
      await act(async () => typeInto(doc.querySelector("textarea")!, "/"));
      expect(doc.querySelector(".acpmux-composer-box > .acpmux-slash-menu")).not.toBeNull();
      await act(async () => typeInto(doc.querySelector("textarea")!, ""));
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
