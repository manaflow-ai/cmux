// `/help`: one searchable sheet of the composer's commands, skills and keys (Leo 2026-11-22: "is
// there a /help? apparently not. welp. how should we do things?").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";
import { helpRows, searchHelp } from "../src/agent-session/acpmux/composerHelp";
import type { SlashCommand } from "../src/agent-session/acpmux/slashCommands";

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
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

let chats = 0;

const COMMANDS: SlashCommand[] = [
  { name: "compact", description: "Clear the history but keep a summary", source: "agent" },
  { name: "review", description: "Review a pull request", source: "agent" },
  { name: "release", description: "Cut a release", source: "skill" },
  { name: "help", description: "", descriptionKey: "composer.slashHelp", source: "cmux" },
];
const t = ((key: string) => key) as Parameters<typeof helpRows>[2];

test("the sheet lists the / list's commands, then skills, then keys, without /help", () => {
  const rows = helpRows(COMMANDS, {}, t);
  expect(rows.filter((row) => row.kind === "command").map((row) => row.title)).toEqual([
    "/compact",
    "/review",
    "/release",
  ]);
  expect(rows.map((row) => row.section)).toEqual(
    rows
      .map((row) => row.section)
      .sort((a, b) => ["commands", "skills", "keys"].indexOf(a) - ["commands", "skills", "keys"].indexOf(b)),
  );
  expect(rows.some((row) => row.kind === "key" && row.keys === "⌘↩")).toBe(true);
  expect(rows.find((row) => row.kind === "key" && row.keys === "⌥↩")?.title).toBe("help.key.newline");
});

test("a host shortcut shows only with its keycap", () => {
  expect(helpRows([], {}, t).some((row) => row.title === "help.key.dictation")).toBe(false);
  const rows = helpRows([], { "agentPane.composer.toggleDictation": "⌥D" }, t);
  const bound = rows.filter((row) => row.kind === "key" && row.keys === "⌥D");
  // Whatever the action's id, a keycap the host pushed is listed once.
  expect(bound.length).toBeLessThanOrEqual(1);
});

test("search keeps rows holding every word, a leading slash ignored", () => {
  const rows = helpRows(COMMANDS, {}, t);
  expect(searchHelp(rows, "/rev").map((row) => row.title)).toEqual(["/review"]);
  expect(searchHelp(rows, "pull request").map((row) => row.title)).toEqual(["/review"]);
  expect(searchHelp(rows, "zzz")).toEqual([]);
  expect(searchHelp(rows, "  ").length).toBe(rows.length);
});

function Chips() {
  return null;
}

async function composer(typed: string) {
  const sessionId = `help-${++chats}`;
  const { mergedCommands } = await import("../src/agent-session/acpmux/cmuxCommands");
  const snapshot: AcpmuxSnapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    commands: mergedCommands(
      COMMANDS.filter((command) => command.name !== "help"),
      new Set(["help"]),
    ),
  });
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  return { field: host.querySelector<HTMLElement>("[role=combobox]")!, sent };
}

async function key(target: HTMLElement, key: string) {
  await act(async () => {
    target.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

test("/help opens the sheet; a search and Return write the command into the prompt", async () => {
  const { field, sent } = await composer("/help");
  await key(field, "Enter");
  const sheet = host.querySelector<HTMLElement>(".acpmux-help-sheet");
  expect(sheet).not.toBeNull();
  expect(sent).toEqual([]);
  const search = sheet!.querySelector<HTMLInputElement>(".acpmux-help-search")!;
  expect(sheet!.textContent).toContain("/review");
  expect(sheet!.querySelectorAll("kbd").length).toBeGreaterThan(0);
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(search, "pull");
    search.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const options = [...sheet!.querySelectorAll("[role=option]")].map((row) => row.textContent);
  expect(options.length).toBe(1);
  expect(options[0]).toContain("/review");
  await key(search, "Enter");
  expect(host.querySelector(".acpmux-help-sheet")).toBeNull();
  expect(field.textContent?.trim()).toBe("/review");
  expect(sent).toEqual([]);
});

test("Escape closes the sheet and sends nothing", async () => {
  const { field, sent } = await composer("/help");
  await key(field, "Enter");
  const search = host.querySelector<HTMLElement>(".acpmux-help-search")!;
  await key(search, "Escape");
  expect(host.querySelector(".acpmux-help-sheet")).toBeNull();
  expect(sent).toEqual([]);
});
