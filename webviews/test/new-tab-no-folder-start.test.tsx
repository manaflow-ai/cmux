// cmux#40938: a New Tab in a fresh workspace inherits the home folder (`~`). Its folder chip reads
// No folder, and a chat started there must start in the host's own start folder: the page sends no
// folder. Before, the page's chips and its slash-command list started the chat in the inherited
// `~` itself (`chat.new {harness, cwd: ~}`), and the pane refused it: "Couldn't start Codex: This
// folder is outside the folders this pane may use."
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "Event",
  "MouseEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
  "MutationObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    ResizeObserver: window.ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  window.localStorage.clear();
});

afterAll(async () => {
  await settleReact();
  window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const HOME = "/Users/you";
const noop = () => {};

/// The folder each chips render was handed: a harness or model pick there sends `chat.new` with
/// exactly this `cwd` (App.tsx DefaultComposerChips `inFolder`). `"none"`: no folder.
function recordingChips(seen: string[]) {
  return function Chips({ cwd }: { snapshot: AcpmuxSnapshot; cwd?: string }) {
    seen.push(cwd ?? "none");
    return <span className="acpmux-chips">Codex</span>;
  };
}

function codexPage(): AcpmuxSnapshot {
  const snapshot = noChat();
  snapshot.summary = { sessionId: "", harness: "codex", model: "m" };
  snapshot.commands = [{ name: "goal", description: "Set a goal" }];
  return snapshot;
}

async function mountScreen(options: { startCwd?: string; seen: string[]; commands: [string, string][] }) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={codexPage()}
        lastAgent="codex"
        home={HOME}
        cwd={HOME}
        {...(options.startCwd ? { startCwd: options.startCwd } : {})}
        knownProjects={[]}
        chips={recordingChips(options.seen)}
        onCommands={(harness, cwd) => options.commands.push([harness, cwd ?? "none"])}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return field.acpmuxMarkdownField!;
}

test("No folder on a New Tab that inherits ~: the chips and the slash list start Codex in no folder, never ~", async () => {
  const seen: string[] = [];
  const commands: [string, string][] = [];
  const field = await mountScreen({ seen, commands });
  // The slash list asks the chat to start (`chat.new {harness, cwd, deferred}`) to read its commands.
  await act(async () => {
    field.focus();
    field.type("/go");
  });
  expect(seen.length).toBeGreaterThan(0);
  expect([...new Set(seen)]).toEqual(["none"]);
  expect(commands).toEqual([["codex", "none"]]);
});

test("the host's start folder is still where the chips and the slash list start the chat", async () => {
  const seen: string[] = [];
  const commands: [string, string][] = [];
  const field = await mountScreen({ startCwd: "/Users/you/src/app", seen, commands });
  await act(async () => {
    field.focus();
    field.type("/go");
  });
  expect([...new Set(seen)]).toEqual(["/Users/you/src/app"]);
  expect(commands).toEqual([["codex", "/Users/you/src/app"]]);
});

test("the classic New Tab page's chips never start the chat in the inherited ~ either", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const seen: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={codexPage()}
        initialKind="agent"
        home={HOME}
        cwd={HOME}
        knownProjects={[]}
        chips={recordingChips(seen)}
        onSubmit={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  expect(seen.length).toBeGreaterThan(0);
  expect([...new Set(seen)]).toEqual(["none"]);
});
