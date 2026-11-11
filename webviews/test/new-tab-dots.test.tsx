// The New Tab page's look dots (Leo 2026-10-23: "1 CLAUDE MINIMAL ... 3 CODEX MINIMAL";
// newtab/tabDots.ts): Claude Minimal and Codex Minimal. A dot keeps no state of its own: it is the
// composer's look. The middle dot (Claude Minimal with the quick actions widget) went with the New Tab
// widgets (Lawrence 2026-11-09: "remove widgets completely"). Arrow keys across the dots are the
// browser's (test/composer-look-dots.test.ts drives them in Chromium).
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { setComposerLook } from "../src/agent-session/acpmux/composerLook";
import { translateNewTab } from "../src/agent-session/acpmux/newtab/strings";
import { NEW_TAB_DOTS, dotName, pickDot, shownDot } from "../src/agent-session/acpmux/newtab/tabDots";
import type { NewTabTemplate } from "../src/agent-session/acpmux/newtab/templates";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

beforeEach(() => setComposerLook("claude"));

afterAll(() => {
  // The look is module state: leave the default for the files after this one.
  setComposerLook("claude");
  window.localStorage.clear();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const storedLook = () => window.localStorage.getItem("cmux.composer.look");

test("the dot shown comes from the look", () => {
  expect(NEW_TAB_DOTS).toEqual(["claude", "codex"]);
  expect(shownDot("claude")).toBe("claude");
  expect(shownDot("codex")).toBe("codex");
});

test("the dots' names: Claude Minimal, Codex Minimal", () => {
  const nt = (key: Parameters<typeof translateNewTab>[0]) => translateNewTab(key, {}, "en");
  expect(NEW_TAB_DOTS.map((dot) => dotName(dot, nt))).toEqual(["Claude Minimal", "Codex Minimal"]);
});

test("a pick sets the look and nothing else", () => {
  pickDot("codex");
  expect(storedLook()).toBe("codex");
  pickDot("claude");
  expect(storedLook()).toBe("claude");
});

async function renderDots(template: NewTabTemplate, calls: [string, unknown][] = []): Promise<Root> {
  const { createRoot } = await import("react-dom/client");
  const { PageDots } = await import("../src/agent-session/acpmux/newtab/PageDots");
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <PageDots
        template={template}
        callNative={async (method, params) => void calls.push([method, params])}
        show={() => {}}
        onCancel={() => {}}
      />,
    ),
  );
  return root;
}

const radios = () => [...host.querySelectorAll<HTMLInputElement>(".nt-look-dots input[type=radio]")];

test("the page draws two dots, the look's one checked, and a click on each picks it", async () => {
  const calls: [string, unknown][] = [];
  const root = await renderDots("minimal", calls);
  try {
    expect(radios().map((radio) => [radio.value, radio.getAttribute("aria-label"), radio.checked])).toEqual([
      ["claude", "Claude Minimal", true],
      ["codex", "Codex Minimal", false],
    ]);
    await act(async () => radios()[1]!.click());
    expect(storedLook()).toBe("codex");
    expect(radios().find((radio) => radio.checked)?.value).toBe("codex");
    // A dot writes no setting.
    expect(calls).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal shows the look dots only; the other styles add the style switch", async () => {
  let root = await renderDots("minimal");
  try {
    expect(host.querySelectorAll(".nt-page-dots .nt-style").length).toBe(1);
  } finally {
    await act(async () => root.unmount());
  }
  for (const template of ["default", "cards"] as const) {
    root = await renderDots(template);
    try {
      expect(host.querySelectorAll(".nt-page-dots .nt-style").length).toBe(2);
    } finally {
      await act(async () => root.unmount());
    }
  }
});
