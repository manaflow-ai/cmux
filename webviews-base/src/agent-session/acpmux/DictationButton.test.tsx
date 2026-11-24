import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DictationButton } from "./DictationButton";
import { DictationCancelButton } from "./DictationListening";
import type { Dictation } from "./dictation";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  // test/preload.ts installs the real pane table; restore it after, never delete it.
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
      "dictation.start": "Dictate",
      "dictation.stop": "Stop dictation",
      "dictation.cancel": "Cancel dictation",
      "dictation.dictateWith": "Dictate with {name}",
    },
  };
  return dom.window.document.getElementById("root")!;
}

async function resetDom(): Promise<void> {
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
}

afterEach(async () => {
  await resetDom();
});

function fakeDictation(state: Dictation["state"], cancelled: string[] = []): Dictation {
  return {
    state,
    notice: null,
    toggle() {},
    finish() {},
    cancel() {
      cancelled.push(state);
    },
    openSettings() {},
    dismiss() {},
  };
}

async function render(state: Dictation["state"]): Promise<HTMLButtonElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ShortcutsContext.Provider value={{ [SHORTCUT_ACTIONS.toggleDictation]: "⇧⌘D" }}>
        <DictationButton dictation={fakeDictation(state)} />
      </ShortcutsContext.Provider>,
    );
  });
  return container.querySelector("button")!;
}

test("starting and finalizing expose the in-progress state to assistive technology", async () => {
  const starting = await render("starting");
  expect(starting.getAttribute("aria-label")).toBe("Stop dictation");
  expect(starting.getAttribute("aria-pressed")).toBe("true");
  expect(starting.getAttribute("aria-busy")).toBe("true");

  await resetDom();

  const finalizing = await render("finalizing");
  expect(finalizing.getAttribute("aria-label")).toBe("Stop dictation");
  expect(finalizing.getAttribute("aria-busy")).toBe("true");
});

test("idle and listening remain settled controls", async () => {
  const idle = await render("idle");
  expect(idle.getAttribute("aria-label")).toBe("Dictate");
  expect(idle.getAttribute("aria-pressed")).toBe("false");
  expect(idle.getAttribute("aria-busy")).toBeNull();

  await resetDom();

  const listening = await render("listening");
  expect(listening.getAttribute("aria-label")).toBe("Stop dictation");
  expect(listening.getAttribute("aria-pressed")).toBe("true");
  expect(listening.getAttribute("aria-busy")).toBeNull();
});

test("a running session's mic stays a mic glyph, pressed; its level shows beside it, not in it", async () => {
  const listening = await render("listening");
  expect(listening.getAttribute("aria-pressed")).toBe("true");
  expect(listening.getAttribute("data-state")).toBe("listening");
  expect(listening.querySelector("svg")).not.toBeNull();
  expect(listening.querySelector(".acpmux-mic-meter")).toBeNull();
});

async function renderCancel(state: Dictation["state"], cancelled: string[]): Promise<HTMLButtonElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<DictationCancelButton dictation={fakeDictation(state, cancelled)} />);
  });
  return container.querySelector("button")!;
}

test("Codex's ✕ cancels the session (drops its words), as Esc does", async () => {
  const cancelled: string[] = [];
  const listening = await renderCancel("listening", cancelled);
  expect(listening.getAttribute("aria-label")).toBe("Cancel dictation");
  await act(async () => listening.click());
  expect(cancelled).toEqual(["listening"]);
});

test("a dictation app as the source names it on the mic; cmux's own keeps Dictate", async () => {
  const { setComposerSettings } = await import("./composerSettings");
  const { setDictationApps } = await import("./dictationSources");
  setDictationApps([{ id: "chatgpt", bundleId: "com.openai.codex" }]);
  setComposerSettings({ dictationSource: "chatgpt" });
  try {
    const named = await render("idle");
    expect(named.getAttribute("data-source")).toBe("chatgpt");
    expect(named.getAttribute("aria-label")).toContain("ChatGPT");
  } finally {
    setComposerSettings({ dictationSource: "cmux" });
    setDictationApps([]);
  }
  await resetDom();
  const own = await render("idle");
  expect(own.getAttribute("data-source")).toBeNull();
  expect(own.getAttribute("aria-label")).toBe("Dictate");
});
