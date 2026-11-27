import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import { VoiceButton, VoiceControl, VoiceStatusView, type VoiceCommand } from "./VoiceControls";
import { setVoiceState, voiceState } from "./voice";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
async function render(node: ReactNode) {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "IS_REACT_ACT_ENVIRONMENT",
    "__cmuxPaneStrings",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  globalThis.__cmuxPaneStrings = {
    en: {
      "voice.start": "Start voice mode",
      "voice.stop": "Stop voice mode",
      "voice.skip": "Skip reading",
      "voice.restart": "Restart voice mode",
    },
  };
  const container = dom.window.document.querySelector("main")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}
afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setVoiceState(null);
});

test("voice is hidden until the native host opts in", async () => {
  const container = await render(<VoiceControl />);
  expect(container.querySelector("button")).toBeNull();
  await act(async () => {
    setVoiceState({ state: "idle", enabled: true });
  });
  expect(container.querySelector("button")?.getAttribute("aria-label")).toBe("Start voice mode");
});

test("a snapshot sent before mount is displayed without another event", async () => {
  setVoiceState({ state: "listening", enabled: true });
  const container = await render(<VoiceControl />);
  expect(container.querySelector("button")?.getAttribute("aria-pressed")).toBe("true");
});

test("an active session remains cancellable after the setting is disabled; IME Escape is ignored", async () => {
  const sent: VoiceCommand[] = [];
  const container = await render(
    <VoiceButton state={{ state: "listening", enabled: false }} command={(c) => sent.push(c)} />,
  );
  await act(async () => {
    container.querySelector("button")!.click();
  });
  expect(sent).toEqual(["voice.cancel"]);
  await act(async () => {
    document.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", isComposing: true, bubbles: true }),
    );
  });
  expect(sent).toHaveLength(1);
  const escape = new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  await act(async () => {
    document.dispatchEvent(escape);
  });
  expect(sent).toEqual(["voice.cancel", "voice.cancel"]);
  expect(escape.defaultPrevented).toBe(true);
});

test("ready click forwards toggle and idle Escape does nothing", async () => {
  const sent: VoiceCommand[] = [];
  const container = await render(
    <VoiceButton state={{ state: "idle", enabled: true }} command={(c) => sent.push(c)} />,
  );
  await act(async () => {
    container.querySelector("button")!.click();
    document.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(sent).toEqual(["voice.toggle"]);
});

test("footer forwards skip and restart and displays native localized status", async () => {
  const sent: VoiceCommand[] = [];
  const container = await render(
    <VoiceStatusView
      state={{ state: "speaking", enabled: true, message: "Parle", restartRequired: true }}
      command={(c) => sent.push(c)}
    />,
  );
  expect(container.querySelector('[role="status"]')?.textContent).toBe("Parle");
  await act(async () => {
    for (const button of container.querySelectorAll("button")) button.click();
  });
  expect(sent).toEqual(["voice.skip", "voice.restart"]);
});

test("malformed native state fails closed and input levels stay finite and bounded", () => {
  setVoiceState({ state: "listening", enabled: true, level: 2 });
  expect(voiceState().level).toBe(1);
  setVoiceState({ state: "listening", enabled: true, level: NaN });
  expect(voiceState().level).toBeUndefined();
  setVoiceState({ state: "unknown", enabled: true });
  expect(voiceState()).toEqual({ state: "idle", enabled: false });
  setVoiceState({ state: "listening", enabled: "true" });
  expect(voiceState().enabled).toBe(false);
});

test("restart stays reachable when the native host is idle without a status message", async () => {
  const sent: VoiceCommand[] = [];
  const container = await render(
    <VoiceStatusView state={{ state: "idle", enabled: true, restartRequired: true }} command={(c) => sent.push(c)} />,
  );
  await act(async () => {
    container.querySelector("button")!.click();
  });
  expect(sent).toEqual(["voice.restart"]);
});
