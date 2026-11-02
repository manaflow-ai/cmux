// A rejected async clipboard and an execCommand("copy") refusal must never produce a
// "Copied" acknowledgement. Exercises the real failed-turn and edit-diff controls.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { TurnFile } from "../src/agent-session/acpmux/diff";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  customElements: dom.window.customElements,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

let acceptAsync = false;
let acceptLegacy = false;
let legacyThrows = false;
const written: string[] = [];
let legacyCalls = 0;
Object.defineProperty(dom.window.navigator, "clipboard", {
  configurable: true,
  value: {
    writeText: async (text: string) => {
      if (!acceptAsync) throw new Error("clipboard.denied");
      written.push(text);
    },
  },
});
Object.defineProperty(dom.window.document, "execCommand", {
  configurable: true,
  value: (command: string) => {
    if (command !== "copy") throw new Error("unexpected execCommand");
    legacyCalls++;
    if (legacyThrows) throw new Error("clipboard.legacy_denied");
    return acceptLegacy;
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { copyTextResult } = await import("../src/agent-session/acpmux/conversation/clipboard");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { EditDiff } = await import("../src/agent-session/acpmux/conversation/EditDiff");
const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

beforeEach(async () => {
  acceptAsync = false;
  acceptLegacy = false;
  legacyThrows = false;
  legacyCalls = 0;
  written.length = 0;
  await act(async () => root.render(null));
});
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
const temporaryFields = () => [...dom.window.document.querySelectorAll("textarea")];

test("async success, fallback success and refused fallback report the actual outcome", async () => {
  acceptAsync = true;
  expect(await copyTextResult("async")).toBe(true);
  expect(written).toEqual(["async"]);
  expect(legacyCalls).toBe(0);

  acceptAsync = false;
  acceptLegacy = true;
  expect(await copyTextResult("fallback")).toBe(true);
  expect(legacyCalls).toBe(1);
  expect(temporaryFields()).toHaveLength(0);

  acceptLegacy = false;
  expect(await copyTextResult("refused")).toBe(false);
  expect(temporaryFields()).toHaveLength(0);
});

test("fallback throw removes temporary textarea and reports failure", async () => {
  legacyThrows = true;
  expect(await copyTextResult("unavailable")).toBe(false);
  expect(temporaryFields()).toHaveLength(0);
});

test("failed-turn Copy error responds to refused copy and later successful retry", async () => {
  const row: AcpmuxRow = {
    id: "failed-turn",
    version: 1,
    at: 1,
    kind: "turnSummary",
    status: "failed",
    error: "the actual underlying failure",
  };
  await act(async () => root.render(<TurnFooter row={row} />));
  const button = host.querySelector<HTMLButtonElement>(".cv-turn-error__raw button")!;
  expect(button).toBeTruthy();
  const copyLabel = button.textContent;
  await act(async () => button.click());
  expect(button.textContent).toBe(copyLabel);
  expect(temporaryFields()).toHaveLength(0);

  acceptLegacy = true;
  await act(async () => button.click());
  expect(button.textContent).toBe("Copied");
});

test("edit-diff Copy stays Copy after refusal, and can recover on retry", async () => {
  const file: TurnFile = {
    path: "src/entry.ts",
    displayPath: "src/entry.ts",
    additions: 1,
    deletions: 0,
    created: false,
    edits: [
      {
        toolId: "edit-1",
        numbered: false,
        hunks: [{ lines: [{ type: "add", text: "export const entry = 1;" }] }],
      },
    ],
  };
  await act(async () => root.render(<EditDiff file={file} />));
  const button = host.querySelector<HTMLButtonElement>(".cv-edit-diff__copy")!;
  expect(button).toBeTruthy();
  const original = button.getAttribute("aria-label");
  await act(async () => button.click());
  expect(button.getAttribute("aria-label")).toBe(original);
  expect(temporaryFields()).toHaveLength(0);

  acceptLegacy = true;
  await act(async () => button.click());
  expect(button.getAttribute("aria-label")).toBe("Copied");
});
