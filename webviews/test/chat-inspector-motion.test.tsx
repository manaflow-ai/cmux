// The Inspector enters from the pane's right edge and leaves the way it came (ui/presence.ts, Leo
// 2026-10-20 directional motion): closed, it stays mounted with its sections while its exit plays,
// takes no input, and unmounts when the exit ends; with motion off it goes at once.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useChatInspector } from "../src/agent-session/acpmux/inspector/ChatInspector";
import {
  resetInspectorState,
  setInspectorOpen,
  setInspectorSection,
  setInspectorWidth,
} from "../src/agent-session/acpmux/inspector/inspectorState";
import { assistant, chat, user } from "../src/gallery/fixtures/acpmux";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/// The transition the page's stylesheet would give a surface with presence: 0 is motion off.
let transition = "0.15s";

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  const computed = dom.window.getComputedStyle.bind(dom.window);
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: (element: Element) => {
      const style = computed(element);
      if (!element.hasAttribute("data-presence")) return style;
      return { opacity: style.opacity, transitionDuration: transition, transitionDelay: "0s" };
    },
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetInspectorState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  transition = "0.15s";
  resetInspectorState();
  setHeaderState({ inspector: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const snapshot = chat([user("Write the release notes", 4), assistant("Done.", 3)]);

/// How many times the chat pane around the Inspector rendered.
let paneRenders = 0;

function Pane() {
  paneRenders++;
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const inspector = useChatInspector({ snapshot, machineName: "Studio", shell });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      {inspector.panel}
    </section>
  );
}

async function mount() {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane />);
  });
  return () => container.querySelector<HTMLElement>("aside.acpmux-chat-inspector");
}

test("the Inspector slides in from the right and back out, keeping its sections until the exit ends", async () => {
  const panel = await mount();
  await act(async () => setInspectorOpen(true));
  const opened = panel();
  expect(opened?.dataset.enter).toBe("right");
  expect(opened?.dataset.presence).toBe("shown");

  await act(async () => setInspectorOpen(false));
  const leaving = panel();
  expect(leaving).toBe(opened);
  expect(leaving?.dataset.presence).toBe("leaving");
  expect(leaving?.hasAttribute("inert")).toBe(true);
  expect(leaving?.querySelector("section.acpmux-chat-inspector-section")).not.toBeNull();

  await act(async () => {
    leaving!.dispatchEvent(new dom!.window.Event("transitionend", { bubbles: true }));
  });
  expect(panel()).toBeNull();
});

test("a reopen during the exit keeps the same panel", async () => {
  const panel = await mount();
  await act(async () => setInspectorOpen(true));
  const opened = panel();
  await act(async () => setInspectorOpen(false));
  await act(async () => setInspectorOpen(true));
  expect(panel()).toBe(opened);
  expect(panel()?.dataset.presence).toBe("shown");
  expect(panel()?.hasAttribute("inert")).toBe(false);
});

test("with motion off the Inspector closes at once", async () => {
  transition = "0s";
  const panel = await mount();
  await act(async () => setInspectorOpen(true));
  expect(panel()).not.toBeNull();
  await act(async () => setInspectorOpen(false));
  expect(panel()).toBeNull();
});

// The chat pane (App.tsx AcpmuxPane) is the whole agent pane: each of its renders redraws the
// transcript, the composer and the header. Opening the Inspector drew it five times in one frame
// (the store change, the presence's `from` and `shown`, the pane's width), a 75-99 ms frame in the
// gallery's `agent-pane.inspector-motion` `reopened` play. The panel's own phases, its width and its
// folds now render the panel alone.
test("opening, closing, resizing and folding the Inspector render the chat pane once per toggle", async () => {
  const panel = await mount();
  const close = async () => {
    await act(async () => setInspectorOpen(false));
    await act(async () => {
      panel()!.dispatchEvent(new dom!.window.Event("transitionend", { bubbles: true }));
    });
    expect(panel()).toBeNull();
  };
  await act(async () => setInspectorOpen(true));
  await close();

  paneRenders = 0;
  await act(async () => setInspectorOpen(true));
  expect(panel()?.dataset.presence).toBe("shown");
  expect(paneRenders).toBe(1);

  paneRenders = 0;
  await act(async () => setInspectorWidth(360));
  await act(async () => setInspectorSection("environment", false));
  expect(panel()?.style.width).toBe("360px");
  expect(paneRenders).toBe(0);

  paneRenders = 0;
  await close();
  expect(paneRenders).toBe(1);
});
