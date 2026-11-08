// Run on N agents clears the composer once its runs started, as a send does, but only the prompt
// it ran: words typed while the runs were starting stay (cmux#38503 review, F2).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { PickerCatalog, PickerHarness } from "../src/agent-session/acpmux/modelCatalogData";
import type { RunVariant } from "../src/agent-session/acpmux/runOnAgents/runOnAgents";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    KeyboardEvent: window.KeyboardEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const harness = (id: string, name: string): PickerHarness => ({
  id,
  name,
  brand: id,
  acpmuxHarness: id,
  installed: true,
  pickable: true,
  models: [],
});
const catalog: PickerCatalog = {
  provisional: false,
  harnesses: [harness("claude", "Claude"), harness("codex", "Codex")],
};

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what} (prompt: ${prompt()})`);
    await settle();
  }
}
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")?.acpmuxMarkdownField;
const prompt = () => markdownField()?.value() ?? "";
async function type(text: string) {
  await act(async () => markdownField()!.setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => markdownField()!.insertTyped(text));
}

/// The composer of chat `sessionId` whose runs wait on the promise `run` answers.
async function render(
  run: (text: string, variants: RunVariant[]) => Promise<unknown>,
  handle?: (value: import("../src/agent-session/acpmux/Composer").ComposerHandle | null) => void,
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const sessionId = "chat-1";
  const snapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={() => null}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        runOnAgents={{ catalog, run }}
        handle={handle}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
}

/// ⌘⌥Return in the prompt opens the panel; its Run starts the runs.
async function runOnAgents() {
  const editor = host.querySelector<HTMLElement>(".acpmux-md")!;
  await act(async () => {
    editor.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Enter", metaKey: true, altKey: true, bubbles: true }),
    );
  });
  await until(() => !!dom.window.document.querySelector(".acpmux-run-on-run"), "the panel");
  const run = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-run-on-run")!;
  await act(async () => run.click());
}

test("the prompt it ran goes once the runs started", async () => {
  const ran: string[] = [];
  await render(async (text) => void ran.push(text));
  await type("Add a NOTICE");
  await runOnAgents();
  await until(() => prompt() === "", "the prompt to clear");
  expect(ran).toEqual(["Add a NOTICE"]);
  expect(dom.window.document.querySelector(".acpmux-run-on")).toBeNull();
});

test("words typed after the prompt while the runs start stay, and the sent prompt goes", async () => {
  let started!: () => void;
  const ran: string[] = [];
  await render((text) => {
    ran.push(text);
    return new Promise<void>((done) => (started = done));
  });
  await type("Add a NOTICE");
  await runOnAgents();
  expect(ran).toEqual(["Add a NOTICE"]);
  await type(" and a CHANGELOG");
  await act(async () => started());
  await settle();
  // As a send keeps what was typed after it (cmux#38892 review, F1).
  expect(prompt()).toBe("and a CHANGELOG");
});

test("a prompt edited while the runs start stays whole", async () => {
  let started!: () => void;
  await render(() => new Promise<void>((done) => (started = done)));
  await type("Add a NOTICE");
  await runOnAgents();
  await act(async () => markdownField()!.setCaret(4));
  await act(async () => markdownField()!.insertTyped("a LICENSE and "));
  await act(async () => started());
  await settle();
  expect(prompt()).toBe("Add a LICENSE and a NOTICE");
});

test("the runs get the prompt as typed, not the field's escaped markdown", async () => {
  const ran: string[] = [];
  await render(async (text) => void ran.push(text));
  await type("Rename *old* to snake_case [v2]");
  await runOnAgents();
  await until(() => ran.length === 1, "the run");
  expect(ran).toEqual(["Rename *old* to snake_case [v2]"]);
});

test("with a file staged, ⌘⌥Return opens no run: a run carries text alone and the file would be left out", async () => {
  const ran: string[] = [];
  let composer: import("../src/agent-session/acpmux/Composer").ComposerHandle | null = null;
  await render(async (text) => void ran.push(text), (value) => void (composer = value));
  const file = { id: "f1", kind: "text", name: "notes.txt", mimeType: "text/plain", size: 5, text: "notes" } as const;
  await act(async () => composer!.restore("Add a NOTICE", [file]));
  await settle();
  const editor = host.querySelector<HTMLElement>(".acpmux-md")!;
  await act(async () => {
    editor.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Enter", metaKey: true, altKey: true, bubbles: true }),
    );
  });
  await settle();
  expect(dom.window.document.querySelector(".acpmux-run-on")).toBeNull();
  expect(ran).toEqual([]);
  expect(prompt()).toContain("Add a NOTICE");
});
