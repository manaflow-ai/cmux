// The header's Session Info toggle reads as on (aria-pressed, the lit ink of header.css) exactly while
// the App's native panel shows, and off once it goes, whichever way it closes: the toggle itself, the
// panel's own close (Esc in AppKit sends `close`), Esc on the page, or a switch to a chat whose panel is
// closed. Leo, 2026-11-02: "the entire ... point was to have it look good work good HAVE THE ...
// TOGGLED HIGHLIGHT".
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import {
  runNativeSessionInfoAction,
  setNativeSessionInfoHost,
} from "../src/agent-session/acpmux/session-info/native/host";
import type { NativeSessionInfo as Model } from "../src/agent-session/acpmux/session-info/native/model";
import { resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { assistant, chat, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const frames = new Map<number, FrameRequestCallback>();
let frameId = 0;
const sent: (Model | null)[] = [];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames.set(++frameId, callback);
      return frameId;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  sent.length = 0;
  setNativeHost(async (method, params) => {
    if (method === "pane.sessionInfo") sent.push(params.info as Model | null);
    return {};
  });
  setNativeSessionInfoHost(true);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setNativeHost(undefined);
  setNativeSessionInfoHost(false);
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  frames.clear();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const first = chat([user("Write the release notes", 4), assistant("Done.", 3)]);
const second: AcpmuxSnapshot = {
  ...chat([user("Fix the build", 2), assistant("Fixed.", 1)]),
  sessionId: "second-chat",
  summary: { ...first.summary, sessionId: "second-chat" } as AcpmuxSnapshot["summary"],
};

let show: (snapshot: AcpmuxSnapshot) => void = () => {};

function Pane() {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const [snapshot, setSnapshot] = useState<AcpmuxSnapshot>(first);
  show = setSnapshot;
  const sessionInfo = useSessionInfo({ snapshot, machineName: "Studio", shell });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <header className="acpmux-header">
        <div className="acpmux-header-tools">{sessionInfo.button}</div>
      </header>
      {sessionInfo.panel}
    </section>
  );
}

async function flushFrames() {
  await act(async () => {
    for (let round = 0; round < 3 && frames.size > 0; round++) {
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(0);
      await Promise.resolve();
    }
  });
}

async function mount() {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  await flushFrames();
  // The page told the App about its panel on mount, so a closed state below is the App's too.
  expect(sent.length).toBeGreaterThan(0);
  const toggle = () => container.querySelector<HTMLButtonElement>("button.acpmux-session-info-toggle")!;
  // A chat's panel may start open (its saved state); every case starts from closed.
  if (toggle().getAttribute("aria-pressed") === "true") {
    expect(sent.at(-1)?.open).toBe(true);
    await act(async () => toggle().click());
    await flushFrames();
  }
  return toggle;
}

/// What the App was last told: whether its panel shows.
const nativeOpen = () => sent.at(-1)?.open === true;
const pressed = (toggle: HTMLButtonElement) => toggle.getAttribute("aria-pressed") === "true";

async function click(toggle: HTMLButtonElement) {
  await act(async () => toggle.click());
  await flushFrames();
}

test("the header toggle is on while the native panel shows and off after it closes", async () => {
  const toggle = await mount();
  expect(pressed(toggle())).toBe(false);
  expect(nativeOpen()).toBe(false);
  // The App draws the panel, the page none of its own.
  expect(document.querySelector("aside.acpmux-session-info")).toBeNull();

  await click(toggle());
  expect(nativeOpen()).toBe(true);
  expect(pressed(toggle())).toBe(true);

  // The toggle again.
  await click(toggle());
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
});

test("the panel's own close (AppKit Esc sends close) turns the toggle off", async () => {
  const toggle = await mount();
  await click(toggle());
  expect(pressed(toggle())).toBe(true);
  await act(async () => runNativeSessionInfoAction("close"));
  await flushFrames();
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
  // And it opens again from the same toggle, lit again.
  await click(toggle());
  expect(nativeOpen()).toBe(true);
  expect(pressed(toggle())).toBe(true);
});

test("Esc on the page with the keyboard on the toggle closes the native panel and turns the toggle off", async () => {
  const toggle = await mount();
  await click(toggle());
  toggle().focus();
  await act(async () => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  await flushFrames();
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
});

test("switching the pane to another chat shows that chat's state on the toggle and in the App", async () => {
  const toggle = await mount();
  // The first chat closed (mount), the second as it was saved (a fresh chat's default).
  await act(async () => show(second));
  await flushFrames();
  expect(pressed(toggle())).toBe(nativeOpen());
  if (pressed(toggle())) await click(toggle());
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
  // Open the second, then back to the first: closed on the toggle and in the App.
  await click(toggle());
  expect(nativeOpen()).toBe(true);
  expect(pressed(toggle())).toBe(true);
  await act(async () => show(first));
  await flushFrames();
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
  // And the second again: open, lit.
  await act(async () => show(second));
  await flushFrames();
  expect(nativeOpen()).toBe(true);
  expect(pressed(toggle())).toBe(true);
});

/// The old host's action script exactly as the App writes it (AgentPaneSessionInfo.actionScript), for
/// the action `id`: its Swift template with the JSON value in place of `\(value.compactText)`.
function oldHostActionScript(id: string): string {
  const swift = readFileSync(
    join(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneSessionInfo.swift"),
    "utf8",
  );
  const template = /return "(window\.cmuxAcpmuxSessionInfo[^"]*\\\(value\.compactText\)[^"]*)"/.exec(swift)?.[1];
  if (!template) throw new Error("AgentPaneSessionInfo.actionScript's template was not found");
  return template.replace("\\(value.compactText)", JSON.stringify(id));
}

test("the old host's close script parses, reaches the page and turns the toggle off", async () => {
  const toggle = await mount();
  await click(toggle());
  expect(pressed(toggle())).toBe(true);
  const script = oldHostActionScript("close");
  // `?.action?(…)` (before #32673) is a syntax error: the close never reached the page.
  expect(script).toContain("?.action?.(");
  expect(() => new vm.Script(script.replace("?.action?.(", "?.action?("))).toThrow(SyntaxError);
  const bridge = { host: setNativeSessionInfoHost, action: runNativeSessionInfoAction };
  const compiled = new vm.Script(script);
  await act(async () => compiled.runInNewContext({ window: { cmuxAcpmuxSessionInfo: bridge } }));
  await flushFrames();
  expect(nativeOpen()).toBe(false);
  expect(pressed(toggle())).toBe(false);
});
