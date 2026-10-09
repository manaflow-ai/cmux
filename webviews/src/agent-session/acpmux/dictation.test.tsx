import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { DictationUpdate } from "./dictationText";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  // An origin, so the page's draft cache (localStorage) works as in the app.
  url: "https://cmux.test/agent-pane",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "localStorage",
    "HTMLElement",
    "customElements",
    "Node",
    "Event",
    "getSelection",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
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
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Event: dom.window.Event,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// App's changes view loads @pierre web components, which reach for DOM classes by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

type Posted = { method: string; params: Record<string, unknown> };
type Host = {
  webkit?: unknown;
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  cmuxAcpmuxBridge?: {
    receive(snapshot: AcpmuxSnapshot): void;
    dictation?(update: DictationUpdate): void;
    applyCustomization(customization: { layout?: Record<string, unknown> }): void;
    applyShortcuts?(labels: Record<string, string>): void;
  };
  cmuxAcpmuxRegistry?: unknown;
};
const host = dom.window as unknown as Host;

const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  sessionId: "s1",
  summary: { sessionId: "s1", turnCount: 0 },
  connection: "connected",
  isWorking: false,
  queue: [],
  catalog: [],
  canLoadOlder: false,
};

/// The pane with a host that records every request: acpmux takes the prompt (`chat.send`), and
/// the WebKit host takes everything else, dictation included.
async function mountPane(options: { refuse?: string } = {}) {
  const posted: Posted[] = [];
  // The composer restores session "s1"'s unsent prompt on mount (composerDraft.ts): an earlier
  // test's words must not reach this pane. The host below answers chat.readDraft with nothing;
  // this clears the page's synchronous draft cache.
  localStorage.clear();
  host.cmuxAcpmuxActions = {
    ready: async () => ({ protocolVersion: 1, transport: "test" }),
    "chat.send": async (params) => {
      posted.push({ method: "chat.send", params });
      return null;
    },
  };
  host.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: Posted) {
          posted.push(message);
          if (options.refuse && message.method.startsWith("dictation."))
            return Promise.resolve({ ok: false, error: { userMessage: options.refuse } });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(AcpmuxApp)));
  await act(async () => host.cmuxAcpmuxBridge!.receive(snapshot));
  // Milkdown makes its editor a task after the composer mounts.
  await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  const document = dom.window.document;
  const field = () => promptField(document);
  /// The prompt's plain text and selection, as dictation reads it.
  const prompt = () => field().handle.text();
  const mic = () => document.querySelector<HTMLButtonElement>(".acpmux-mic")!;
  const send = async (update: Partial<DictationUpdate> & Pick<DictationUpdate, "state">) => {
    await act(async () => host.cmuxAcpmuxBridge!.dictation!({ text: "", level: 0, cancelled: false, ...update }));
  };
  /// Types the whole prompt, then puts the caret at `caret`.
  const type = async (value: string, caret = value.length) => {
    await act(async () => {
      typeInto(field(), value);
      field().handle.setCaret(caret);
    });
  };
  const composition = (type: "compositionstart" | "compositionend") =>
    act(async () => {
      field().element.dispatchEvent(new dom.window.Event(type));
    });
  /// The dictation and send requests, without the pane's other host calls (checkpoints, git).
  const methods = () =>
    posted
      .map((message) => message.method)
      .filter((method) => method.startsWith("dictation.") || method === "chat.send");
  const unmount = async () => {
    await act(async () => root.unmount());
    delete host.webkit;
    delete host.cmuxAcpmuxActions;
    delete host.cmuxAcpmuxRegistry;
  };
  return { document, prompt, field, mic, send, posted, methods, unmount, type, composition };
}

describe("composer dictation", () => {
  test("the mic toggles native dictation and the words land at the cursor", async () => {
    const pane = await mountPane();
    try {
      await pane.type("Please  now", 7);
      expect(pane.mic().getAttribute("aria-label")).toBe("Dictate");
      // The mic is the composer's accessory, just before Send.
      expect(pane.mic().parentElement?.className).toBe("acpmux-composer-actions");
      expect(pane.mic().nextElementSibling?.classList.contains("acpmux-send")).toBe(true);
      await act(async () => pane.mic().click());
      expect(pane.methods()).toEqual(["dictation.toggle"]);
      await pane.send({ state: "starting" });
      await pane.send({ state: "listening", level: 0.6 });
      expect(pane.mic().dataset.state).toBe("listening");
      expect(pane.mic().getAttribute("aria-label")).toBe("Stop dictation");
      expect(pane.mic().querySelectorAll(".acpmux-mic-meter span").length).toBe(5);
      await pane.send({ state: "listening", text: "fix the", level: 0.4 });
      await pane.send({ state: "listening", text: "fix the bug", level: 0.4 });
      expect(pane.prompt().value).toBe("Please fix the bug now");
      await pane.send({ state: "finalizing", text: "fix the bug" });
      await pane.send({ state: "idle", text: "fix the bug" });
      expect(pane.prompt().value).toBe("Please fix the bug now");
      // The composer heard the words as typing.
      expect(pane.field().value).toBe("Please fix the bug now");
      expect(pane.mic().dataset.state).toBe("idle");
      // Nothing was sent: dictated text waits for the user.
      expect(pane.methods()).toEqual(["dictation.toggle"]);
    } finally {
      await pane.unmount();
    }
  });

  test("the mic's tooltip names the live Toggle Dictation shortcut", async () => {
    const pane = await mountPane();
    try {
      expect(pane.mic().title).toBe("Dictate");
      await act(async () => host.cmuxAcpmuxBridge!.applyShortcuts!({ "palette.toggleDictation": "⌃⌘V" }));
      expect(pane.mic().title).toBe("Dictate (⌃⌘V)");
    } finally {
      await pane.unmount();
    }
  });

  test("Esc cancels a running session and its words leave the prompt", async () => {
    const pane = await mountPane();
    try {
      await pane.type("keep ", 5);
      const escape = () =>
        pane.document.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
        );
      // Idle: Esc is not ours.
      expect(escape()).toBe(true);
      await pane.send({ state: "listening", text: "drop this" });
      expect(pane.prompt().value).toBe("keep drop this");
      expect(escape()).toBe(false);
      expect(pane.methods()).toEqual(["dictation.cancel"]);
      await pane.send({ state: "idle", cancelled: true });
      expect(pane.prompt().value).toBe("keep ");
    } finally {
      await pane.unmount();
    }
  });

  test("a denied microphone shows why, with a link to System Settings", async () => {
    const pane = await mountPane();
    try {
      await pane.send({ state: "starting" });
      await pane.send({
        state: "denied",
        permission: "microphone",
        message: "Dictation needs microphone access.",
        settingsLabel: "Open System Settings",
      });
      const notice = pane.document.querySelector(".acpmux-dictation-notice")!;
      expect(notice.getAttribute("role")).toBe("alert");
      expect(notice.textContent).toContain("Dictation needs microphone access.");
      const [settings, dismiss] = [...notice.querySelectorAll("button")];
      await act(async () => settings!.click());
      expect(pane.posted.at(-1)).toMatchObject({
        method: "dictation.openSettings",
        params: { permission: "microphone" },
      });
      await act(async () => dismiss!.click());
      expect(pane.document.querySelector(".acpmux-dictation-notice")).toBeNull();
      expect(pane.mic().dataset.state).toBe("denied");
    } finally {
      await pane.unmount();
    }
  });

  test("auto-send is opt-in through layout.json", async () => {
    const pane = await mountPane();
    try {
      await act(async () => host.cmuxAcpmuxBridge!.applyCustomization({ layout: { dictation: { autoSend: true } } }));
      await pane.send({ state: "listening", text: "ship it" });
      await pane.send({ state: "idle", text: "ship it" });
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      // The send clears the prompt, and the host then persists the empty draft (chat.writeDraft).
      expect(pane.methods()).toEqual(["chat.send"]);
      expect(pane.posted.find((message) => message.method === "chat.send")).toMatchObject({
        params: { text: "ship it" },
      });
      expect(pane.prompt().value).toBe("");
    } finally {
      // Layout is pane-global: a failed assertion above must not leave auto-send on for later tests.
      await act(async () => host.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
      await pane.unmount();
    }
  });

  test("closing the pane mid-session releases the microphone", async () => {
    const pane = await mountPane();
    await pane.send({ state: "listening", text: "half" });
    await pane.unmount();
    expect(pane.methods()).toEqual(["dictation.cancel"]);
  });

  test("rapid toggling sends every press and follows the host's state", async () => {
    const pane = await mountPane();
    try {
      for (let press = 0; press < 4; press += 1) await act(async () => pane.mic().click());
      expect(pane.methods()).toEqual(["dictation.toggle", "dictation.toggle", "dictation.toggle", "dictation.toggle"]);
      // The host settles it: started, cancelled while starting, started, stopped.
      await pane.send({ state: "starting" });
      await pane.send({ state: "idle", cancelled: true });
      await pane.send({ state: "starting" });
      await pane.send({ state: "listening", text: "ok" });
      await pane.send({ state: "idle", text: "ok" });
      expect(pane.prompt().value).toBe("ok");
      expect(pane.mic().dataset.state).toBe("idle");
    } finally {
      await pane.unmount();
    }
  });

  test("each pane starts from an empty prompt, whatever an earlier pane left unsent", async () => {
    localStorage.setItem("cmux.acpmux.composer-draft.s1", "left over");
    const pane = await mountPane();
    try {
      expect(pane.prompt().value).toBe("");
    } finally {
      await pane.unmount();
    }
  });

  test("closing the pane right after a press, before any update, still releases the microphone", async () => {
    const pane = await mountPane();
    await act(async () => pane.mic().click());
    await pane.unmount();
    expect(pane.methods()).toEqual(["dictation.toggle", "dictation.cancel"]);
  });

  test("Esc that closes an input method's candidates does not cancel dictation", async () => {
    const pane = await mountPane();
    try {
      await pane.send({ state: "listening", text: "words" });
      const composing = new dom.window.KeyboardEvent("keydown", {
        key: "Escape",
        bubbles: true,
        cancelable: true,
        isComposing: true,
      });
      expect(pane.document.dispatchEvent(composing)).toBe(true);
      expect(pane.methods()).toEqual([]);
    } finally {
      await pane.unmount();
    }
  });

  test("words arriving during an input method composition wait for it to end", async () => {
    const pane = await mountPane();
    try {
      await pane.send({ state: "listening", text: "hello" });
      await pane.composition("compositionstart");
      await pane.send({ state: "listening", text: "hello world" });
      expect(pane.prompt().value).toBe("hello");
      await pane.composition("compositionend");
      expect(pane.prompt().value).toBe("hello world");
    } finally {
      await pane.unmount();
    }
  });

  test("level ticks move the meter without moving the caret out of the words", async () => {
    const pane = await mountPane();
    try {
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.2 });
      await act(async () => pane.field().handle.setCaret(4));
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.7 });
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.5 });
      expect(pane.prompt().selectionStart).toBe(4);
      expect(pane.prompt().value).toBe("fix the bug now");
      // A rolling waveform: the newest level on the right, earlier ones to its left.
      const bars = [...pane.mic().querySelectorAll<HTMLElement>(".acpmux-mic-meter span")].map(
        (bar) => bar.style.transform,
      );
      expect(bars).toEqual([
        "scaleY(0.18)",
        "scaleY(0.18)",
        `scaleY(${0.2 * 1.4})`,
        `scaleY(${0.7 * 1.4})`,
        `scaleY(${0.5 * 1.4})`,
      ]);
    } finally {
      await pane.unmount();
    }
  });

  test("the waveform keeps the last five levels and a new session starts from silence", async () => {
    const pane = await mountPane();
    const bars = () =>
      [...pane.mic().querySelectorAll<HTMLElement>(".acpmux-mic-meter span")].map((bar) => bar.style.transform);
    try {
      for (const level of [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]) await pane.send({ state: "listening", level });
      expect(bars()).toEqual([0.2, 0.3, 0.4, 0.5, 0.6].map((level) => `scaleY(${level * 1.4})`));
      await pane.send({ state: "failed", message: "The microphone stopped." });
      await pane.send({ state: "listening", level: 0.5 });
      expect(bars()).toEqual(["scaleY(0.18)", "scaleY(0.18)", "scaleY(0.18)", "scaleY(0.18)", `scaleY(${0.5 * 1.4})`]);
    } finally {
      await pane.unmount();
    }
  });

  test("auto-send does not send a draft typed after the dictated words were sent", async () => {
    const pane = await mountPane();
    try {
      await act(async () => host.cmuxAcpmuxBridge!.applyCustomization({ layout: { dictation: { autoSend: true } } }));
      await pane.send({ state: "listening", text: "first message" });
      await pane.type("typing new");
      await pane.send({ state: "idle", text: "first message" });
      expect(pane.methods()).not.toContain("chat.send");
      expect(pane.prompt().value).toBe("typing new");
    } finally {
      await act(async () => host.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
      await pane.unmount();
    }
  });

  test("a cancel that arrives during a composition is not lost behind the next session", async () => {
    const pane = await mountPane();
    try {
      await pane.type("keep ", 5);
      await pane.send({ state: "listening", text: "drop this" });
      await pane.composition("compositionstart");
      await pane.send({ state: "idle", cancelled: true });
      await pane.send({ state: "starting" });
      await pane.composition("compositionend");
      expect(pane.prompt().value).toBe("keep ");
    } finally {
      await pane.unmount();
    }
  });

  test("a refused toggle shows the host's reason", async () => {
    const pane = await mountPane({ refuse: "Dictation is busy in another window." });
    try {
      await act(async () => pane.mic().click());
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      expect(pane.document.querySelector(".acpmux-dictation-notice")?.textContent).toContain(
        "Dictation is busy in another window.",
      );
    } finally {
      await pane.unmount();
    }
  });
});
