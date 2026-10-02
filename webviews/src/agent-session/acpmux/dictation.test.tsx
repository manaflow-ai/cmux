import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { DictationUpdate } from "./dictationText";

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
    "customElements",
    "Node",
    "Event",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
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

const { act, createElement } = await import("react").then((react) => ({
  act: react.act,
  createElement: react.createElement,
}));
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

type Posted = { method: string; params: Record<string, unknown> };

/// The pane with a host that records every request and answers the handshake with no daemon.
async function mountPane(options: { refuse?: string } = {}) {
  const posted: Posted[] = [];
  const host = dom.window as unknown as Record<string, unknown>;
  host.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: Posted) {
          posted.push(message);
          if (message.method === "ready")
            return Promise.resolve({ ok: true, value: { protocolVersion: 1, transport: "none" } });
          if (options.refuse && message.method.startsWith("dictation."))
            return Promise.resolve({ ok: false, error: { userMessage: options.refuse } });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(AcpmuxApp)));
  const document = dom.window.document;
  const prompt = document.querySelector<HTMLTextAreaElement>("textarea[name=prompt]")!;
  const mic = () => document.querySelector<HTMLButtonElement>(".acpmux-mic")!;
  const send = async (update: Partial<DictationUpdate> & Pick<DictationUpdate, "state">) => {
    await act(async () => dom.window.cmuxAcpmuxBridge!.dictation!({ text: "", level: 0, cancelled: false, ...update }));
  };
  /// Types into the prompt the way the browser does: the composer keeps the text as state.
  const type = async (value: string, caret = value.length) => {
    await act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!.call(prompt, value);
      prompt.setSelectionRange(caret, caret);
      prompt.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  };
  const methods = () => posted.map((message) => message.method).filter((method) => method !== "ready");
  const unmount = async () => {
    await act(async () => root.unmount());
    delete host.webkit;
    delete host.cmuxAcpmuxRegistry;
  };
  return { document, prompt, mic, send, posted, methods, unmount, type };
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
      expect(pane.prompt.value).toBe("Please fix the bug now");
      await pane.send({ state: "finalizing", text: "fix the bug" });
      await pane.send({ state: "idle", text: "fix the bug" });
      expect(pane.prompt.value).toBe("Please fix the bug now");
      expect(pane.mic().dataset.state).toBe("idle");
      // Nothing was sent: dictated text waits for the user.
      expect(pane.methods()).toEqual(["dictation.toggle"]);
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
      expect(pane.prompt.value).toBe("keep drop this");
      expect(escape()).toBe(false);
      expect(pane.methods()).toEqual(["dictation.cancel"]);
      await pane.send({ state: "idle", cancelled: true });
      expect(pane.prompt.value).toBe("keep ");
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
      await act(async () =>
        dom.window.cmuxAcpmuxBridge!.applyCustomization({ layout: { dictation: { autoSend: true } } }),
      );
      await pane.send({ state: "listening", text: "ship it" });
      await pane.send({ state: "idle", text: "ship it" });
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
      expect(pane.posted.at(-1)).toMatchObject({ method: "chat.send", params: { text: "ship it" } });
      await act(async () => dom.window.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
    } finally {
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
      expect(pane.prompt.value).toBe("ok");
      expect(pane.mic().dataset.state).toBe("idle");
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
      pane.prompt.dispatchEvent(new dom.window.Event("compositionstart"));
      await pane.send({ state: "listening", text: "hello world" });
      expect(pane.prompt.value).toBe("hello");
      pane.prompt.dispatchEvent(new dom.window.Event("compositionend"));
      expect(pane.prompt.value).toBe("hello world");
    } finally {
      await pane.unmount();
    }
  });

  test("level ticks move the meter without moving the caret out of the words", async () => {
    const pane = await mountPane();
    try {
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.2 });
      pane.prompt.setSelectionRange(4, 4);
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.7 });
      await pane.send({ state: "listening", text: "fix the bug now", level: 0.5 });
      expect(pane.prompt.selectionStart).toBe(4);
      expect(pane.prompt.value).toBe("fix the bug now");
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

  test("auto-send does not send a draft typed after the dictated words were sent", async () => {
    const pane = await mountPane();
    try {
      await act(async () =>
        dom.window.cmuxAcpmuxBridge!.applyCustomization({ layout: { dictation: { autoSend: true } } }),
      );
      await pane.send({ state: "listening", text: "first message" });
      await pane.type("typing new");
      await pane.send({ state: "idle", text: "first message" });
      expect(pane.methods()).not.toContain("chat.send");
      expect(pane.prompt.value).toBe("typing new");
      await act(async () => dom.window.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
    } finally {
      await pane.unmount();
    }
  });

  test("a cancel that arrives during a composition is not lost behind the next session", async () => {
    const pane = await mountPane();
    try {
      await pane.type("keep ", 5);
      await pane.send({ state: "listening", text: "drop this" });
      pane.prompt.dispatchEvent(new dom.window.Event("compositionstart"));
      await pane.send({ state: "idle", cancelled: true });
      await pane.send({ state: "starting" });
      pane.prompt.dispatchEvent(new dom.window.Event("compositionend"));
      expect(pane.prompt.value).toBe("keep ");
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
