// The compact picker returns the keyboard to the composer's prompt after changing only effort.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { effortLevel, openEffort } from "./support/effortDropdown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let prompt: HTMLTextAreaElement | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  prompt?.remove();
  prompt = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function openPicker(
  efforts: string[] | undefined,
  inline: boolean,
  effortPicks: string[] = [],
  effortsDeclared?: boolean,
) {
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const { PromptFocus } = await import("../src/agent-session/acpmux/promptFocus");
  const model = {
    id: "claude-opus-5-5",
    name: "Opus 5.5",
    efforts: efforts ?? [],
    ...(effortsDeclared === undefined ? {} : { effortsDeclared }),
  };
  root = (await import("react-dom/client")).createRoot(host);
  await act(async () =>
    root!.render(
      <PromptFocus.Provider value={() => prompt?.focus()}>
        <ModelPicker
          catalog={[{ id: "claude", name: "Claude Code", models: [model] }]}
          harness="claude"
          model={model.id}
          label={model.name}
          efforts={[]}
          recents={[]}
          quick={{
            effort: {
              levels: [
                { id: "low", name: "Low" },
                { id: "high", name: "High" },
                { id: "ultracode", name: "Ultracode" },
              ],
              current: "high",
              onPick: (value) => effortPicks.push(value),
            },
          }}
          harnessFixed
          onCombo={inline ? () => undefined : undefined}
          onLand={() => undefined}
          onEffort={() => undefined}
        />
      </PromptFocus.Provider>,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
}

// Focus returns on a later turn; poll it against a deadline instead of one fixed wait.
async function focusSettles(done: () => boolean) {
  const deadline = Date.now() + 2_000;
  while (!done() && Date.now() < deadline) {
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  }
}

test("the current model's inline effort pick returns focus to the prompt through ModelPicker", async () => {
  prompt = document.createElement("textarea");
  document.body.append(prompt);
  const effortPicks: string[] = [];
  await openPicker(["low", "high"], true, effortPicks);
  const segment = await effortLevel(host.ownerDocument, "Opus 5.5 · Low");
  expect(segment).not.toBeNull();
  await act(async () => segment!.click());
  await focusSettles(() => document.activeElement === prompt);
  expect(effortPicks).toEqual(["low"]);
  expect(document.activeElement).toBe(prompt);
});

test.each([
  { capability: "absent", inline: true },
  { capability: "empty", inline: true },
  { capability: "absent", inline: false },
  { capability: "empty", inline: false },
])("ModelPicker preserves $capability efforts with inline=$inline", async ({ capability, inline }) => {
  await openPicker(capability === "empty" ? [] : undefined, inline, [], capability === "empty");
  expect(document.querySelector(".acpmux-quick-menu")).not.toBeNull();
  expect(await openEffort(document)).toHaveLength(capability === "absent" && inline ? 3 : 0);
  const effortSubmenu = [...document.querySelectorAll(".acpmux-quick-sub")].find((row) =>
    row.textContent?.startsWith("Effort"),
  );
  expect(Boolean(effortSubmenu)).toBe(capability === "absent" && !inline);
});

test("a direct catalog's unmarked empty effort list remains explicitly unsupported", async () => {
  await openPicker([], true, [], undefined);
  expect(await openEffort(document)).toHaveLength(0);
});

test("the running model uses live session levels over stale catalog efforts", async () => {
  await openPicker(["low"], true);
  expect(await openEffort(document)).toHaveLength(3);
  expect(document.querySelector('[aria-label="Opus 5.5 · High"]')).not.toBeNull();
});
