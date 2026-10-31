import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DictationButton } from "./DictationButton";
import { DictationFinishButton } from "./DictationListening";
import type { Dictation } from "./dictation";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "./shortcuts";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
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
      "dictation.finish": "Finish dictation",
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
  dom?.window.close();
  dom = undefined;
  delete globalThis.__cmuxPaneStrings;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
}

afterEach(async () => {
  await resetDom();
});

function fakeDictation(state: Dictation["state"], finished: string[] = []): Dictation {
  return {
    state,
    notice: null,
    toggle() {},
    finish() {
      finished.push(state);
    },
    cancel() {},
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
  expect(starting.getAttribute("aria-live")).toBe("polite");
  expect(starting.getAttribute("aria-atomic")).toBe("true");

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
  expect(idle.getAttribute("aria-live")).toBe("polite");

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

async function renderFinish(state: Dictation["state"], finished: string[]): Promise<HTMLButtonElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<DictationFinishButton dictation={fakeDictation(state, finished)} />);
  });
  return container.querySelector("button")!;
}

test("the finish key finishes the session (keeps its words) and waits while the last words land", async () => {
  const finished: string[] = [];
  const listening = await renderFinish("listening", finished);
  expect(listening.getAttribute("aria-label")).toBe("Finish dictation");
  expect(listening.disabled).toBe(false);
  await act(async () => listening.click());
  expect(finished).toEqual(["listening"]);

  await resetDom();

  const finalizing = await renderFinish("finalizing", finished);
  expect(finalizing.disabled).toBe(true);
});
