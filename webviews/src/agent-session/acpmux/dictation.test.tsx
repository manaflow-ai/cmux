import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { DictationUpdate } from "./dictationText";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "Event", "ResizeObserver", "requestAnimationFrame", "cancelAnimationFrame", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Event: dom.window.Event,
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react").then((react) => ({ act: react.act, createElement: react.createElement }));
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

type Posted = { method: string; params: Record<string, unknown> };

/// The pane with a host that records every request and answers the handshake with no daemon.
async function mountPane() {
  const posted: Posted[] = [];
  const host = dom.window as unknown as Record<string, unknown>;
  host.webkit = { messageHandlers: { agentSession: { postMessage(message: Posted) {
    posted.push(message);
    if (message.method === "ready") return Promise.resolve({ ok: true, value: { protocolVersion: 1, transport: "none" } });
    return Promise.resolve({ ok: true, value: null });
  } } } };
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(createElement(AcpmuxApp)));
  const document = dom.window.document;
  const prompt = document.querySelector<HTMLTextAreaElement>("textarea[name=prompt]")!;
  const mic = () => document.querySelector<HTMLButtonElement>(".acpmux-mic")!;
  const send = async (update: Partial<DictationUpdate> & Pick<DictationUpdate, "state">) => {
    await act(async () => dom.window.cmuxAcpmuxBridge!.dictation!({ text: "", level: 0, cancelled: false, ...update }));
  };
  const methods = () => posted.map((message) => message.method).filter((method) => method !== "ready");
  const unmount = async () => {
    await act(async () => root.unmount());
    delete host.webkit;
    delete host.cmuxAcpmuxRegistry;
  };
  return { document, prompt, mic, send, posted, methods, unmount };
}

describe("composer dictation", () => {
  test("the mic toggles native dictation and the words land at the cursor", async () => {
    const pane = await mountPane();
    try {
      pane.prompt.value = "Please  now";
      pane.prompt.setSelectionRange(7, 7);
      expect(pane.mic().getAttribute("aria-label")).toBe("Dictate");
      await act(async () => pane.mic().click());
      expect(pane.methods()).toEqual(["dictation.toggle"]);
      await pane.send({ state: "starting" });
      await pane.send({ state: "listening", level: 0.6 });
      expect(pane.mic().dataset.state).toBe("listening");
      expect(pane.mic().getAttribute("aria-label")).toBe("Stop dictation");
      expect(pane.mic().querySelectorAll(".acpmux-mic-meter span").length).toBe(4);
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
      pane.prompt.value = "keep ";
      pane.prompt.setSelectionRange(5, 5);
      const escape = () => pane.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
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
      await pane.send({ state: "denied", permission: "microphone", message: "Dictation needs microphone access.", settingsLabel: "Open System Settings" });
      const notice = pane.document.querySelector(".acpmux-dictation-notice")!;
      expect(notice.getAttribute("role")).toBe("alert");
      expect(notice.textContent).toContain("Dictation needs microphone access.");
      const [settings, dismiss] = [...notice.querySelectorAll("button")];
      await act(async () => settings!.click());
      expect(pane.posted.at(-1)).toMatchObject({ method: "dictation.openSettings", params: { permission: "microphone" } });
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
      await act(async () => dom.window.cmuxAcpmuxBridge!.applyCustomization({ layout: { dictation: { autoSend: true } } }));
      await pane.send({ state: "listening", text: "ship it" });
      await pane.send({ state: "idle", text: "ship it" });
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
});
