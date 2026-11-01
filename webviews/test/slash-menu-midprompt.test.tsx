// The `/` menu mid-prompt (Lucas 2026-11-02, as Codex and Claude Code desktop): a `/` after a space or a
// line break opens it for the word after it, listing only the commands the agent reads as text (cmux's
// own run here only from the prompt's start); a pick writes `/name ` over the typed word, the text
// around it kept, as one undo step; a `/name` that names a command draws blue.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

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
  "MouseEvent",
  "CompositionEvent",
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
    MouseEvent: window.MouseEvent,
    CompositionEvent: window.CompositionEvent,
  });
  // jsdom lays nothing out: a range has no boxes, which ProseMirror reads to scroll the caret into view.
  const box = { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0 };
  Object.assign(window.Range.prototype, { getClientRects: () => [], getBoundingClientRect: () => box });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

let chats = 0;

/// A Claude chat whose list has one of cmux's own commands, a harness built-in and two skills.
function chat(): AcpmuxSnapshot {
  const sessionId = `midprompt-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    commands: [
      { name: "model", description: "", descriptionKey: "picker.model", source: "cmux" },
      { name: "compact", description: "Clear the history but keep a summary", source: "agent" },
      { name: "review-pr", description: "Review a pull request", source: "skill" },
      { name: "release", description: "Cut a release", source: "skill" },
    ],
  });
}

async function composer(snapshot: AcpmuxSnapshot, typed: string) {
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
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
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
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const prompt = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  return { field, prompt, sent };
}

const menu = () => host.querySelector("#acpmux-slash-menu");
const names = () =>
  [...host.querySelectorAll<HTMLElement>("#acpmux-slash-menu [role='option'] .acpmux-slash-name")].map((row) =>
    row.textContent?.trim(),
  );
const blue = () => [...host.querySelectorAll(".acpmux-slash-token")].map((token) => token.textContent);

async function press(field: HTMLElement, key: string) {
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key, keyCode: 13, bubbles: true, cancelable: true }));
  });
}

test("a `/` at the start lists every command, cmux's own and the harness's built-ins included", async () => {
  await composer(chat(), "/");
  expect(names()).toEqual(["/model", "/compact", "/review-pr", "/release"]);
  // With no match there, the empty state, as before.
  await composer(chat(), "/zzz");
  expect(menu()).not.toBeNull();
  expect(names()).toEqual([]);
});

test("mid-prompt the menu lists only skills and prompts, and opens only on a match", async () => {
  const { field } = await composer(chat(), "fix it /");
  expect(names()).toEqual(["/review-pr", "/release"]);
  expect(field.getAttribute("aria-activedescendant")).toBe("acpmux-slash-0");
  await composer(chat(), "fix it /re");
  expect(names()).toEqual(["/review-pr", "/release"]);
  // cmux's own command and the built-in run only from the start: nothing to offer, no menu.
  await composer(chat(), "fix it /mod");
  expect(menu()).toBeNull();
  await composer(chat(), "fix it /comp");
  expect(menu()).toBeNull();
  await composer(chat(), "use /tmp");
  expect(menu()).toBeNull();
});

test("an input method's text opens the menu once it is committed, not while it composes", async () => {
  const { prompt } = await composer(chat(), "fix it ");
  const editor = host.querySelector<HTMLElement>(".acpmux-md-field [contenteditable]")!;
  await act(async () => {
    editor.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
  });
  await act(async () => prompt.insertText("/re"));
  expect(menu()).toBeNull();
  await act(async () => {
    editor.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: "/re" }));
  });
  expect(names()).toEqual(["/review-pr", "/release"]);
});

test("a `/` inside a word, a path or a URL opens nothing", async () => {
  await composer(chat(), "src/app");
  expect(menu()).toBeNull();
  await composer(chat(), "open http://x/y");
  expect(menu()).toBeNull();
  await composer(chat(), "look in /usr/lo");
  expect(menu()).toBeNull();
});

test("Return writes the pick in place, keeps the text around it, and one undo takes it back", async () => {
  const { field, prompt } = await composer(chat(), "fix the build then /re it");
  await act(async () => prompt.setCaret("fix the build then /re".length));
  expect(names()).toEqual(["/review-pr", "/release"]);
  await press(field, "Enter");
  expect(menu()).toBeNull();
  expect(prompt.plainText()).toBe("fix the build then /review-pr it");
  expect(prompt.caret()).toBe("fix the build then /review-pr ".length);
  await act(async () => prompt.undo());
  expect(prompt.plainText()).toBe("fix the build then /re it");
});

test("a mouse pick and Tab write in place too; the caret leaving the word closes the menu", async () => {
  const { field, prompt } = await composer(chat(), "ship it /rel");
  const row = host.querySelectorAll<HTMLElement>("#acpmux-slash-menu [role='option']")[0]!;
  await act(async () => {
    row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(prompt.plainText()).toBe("ship it /release ");
  await act(async () => prompt.insertTyped("/rev"));
  expect(names()).toEqual(["/review-pr"]);
  await act(async () => prompt.setCaret(2));
  expect(menu()).toBeNull();
  await act(async () => prompt.setCaret("ship it /release /rev".length));
  await press(field, "Tab");
  expect(prompt.plainText()).toBe("ship it /release /review-pr ");
});

test("a command word draws blue where it counts as one; others stay plain", async () => {
  await composer(chat(), "/model then /review-pr and /compact and /nope in src/release");
  expect(blue()).toEqual(["/model", "/review-pr"]);
  await composer(chat(), "fix /model or /compact");
  expect(blue()).toEqual([]);
  await composer(chat(), "/compact now");
  expect(blue()).toEqual(["/compact"]);
});

/// A Codex chat: codex-acp lists its skills as `$name`.
function codexChat(): AcpmuxSnapshot {
  const sessionId = `midprompt-codex-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "codex", family: "codex", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    commands: [
      { name: "init", description: "Create an AGENTS.md file", source: "agent" },
      { name: "$emil-color", description: "Colour in CSS", source: "skill" },
      { name: "$emil-design-foundations", description: "Design judgment", source: "skill" },
    ],
  });
}

test("a Codex skill lists, writes and colours without its `$`, and goes to Codex as `/$name`", async () => {
  const { field, prompt, sent } = await composer(codexChat(), "Use /emil-d");
  expect(names()).toEqual(["/emil-design-foundations"]);
  await press(field, "Enter");
  expect(prompt.plainText()).toBe("Use /emil-design-foundations ");
  expect(blue()).toEqual(["/emil-design-foundations"]);
  await act(async () => prompt.insertTyped("in src/emil-color"));
  await press(field, "Enter");
  expect(sent).toEqual(["Use /$emil-design-foundations in src/emil-color"]);
});

test("a prompt that comes back to the composer reads a Codex skill as typed", async () => {
  // `composer` puts its text in through `restore`, as a refused send or a taken-back steer does: the
  // prompt as it went.
  const { prompt, sent, field } = await composer(codexChat(), "use /$emil-color now");
  expect(prompt.plainText()).toBe("use /emil-color now");
  await press(field, "Enter");
  expect(sent).toEqual(["use /$emil-color now"]);
});
