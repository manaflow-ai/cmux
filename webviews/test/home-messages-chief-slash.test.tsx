// `/` in a Chief chat's message box on the Messages page (the user, 2026-11-09: "/ calls suggestions
// in chief", as the agent chats do). #37777 moved the Chief chat to this page and the native `/` menu
// went with the native transcript: before this, `/` here listed nothing. The list is the Chief's
// skills (`chief.skills`, the host's `chief.engine.get` offered.skills), read once on a fresh `/`;
// typing filters it, Up/Down and Tab or Return or a click pick, Escape closes it, a path shows none.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { ChiefSkills, CHIEF_SKILLS_OP, parseChiefSkills, chiefSkillMatches } = await import(
  "../src/pages/home-messages/transcript/chiefSkills"
);
type PageClient = import("../src/pages/shared/pageClient").PageClient;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createTranscriptStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

const SKILLS = {
  skills: [
    { name: "cmux-views", description: "Open cmux views", source: "chief" },
    { name: "triage", description: "Sort the inbox", source: "chief" },
    { name: "emil-prototype", description: "Prototype a UI", source: "claude" },
    { name: "ai-sdk", description: "Vercel AI SDK", source: "plugin:vercel" },
  ],
};

/** A host that answers `chief.skills` (or fails) and counts the asks. */
function skillHost(answer: unknown | Error) {
  const calls: Record<string, unknown>[] = [];
  const host = {
    call: async <T,>(op: string, params: Record<string, unknown> = {}) => {
      if (op !== CHIEF_SKILLS_OP) throw new Error(`unexpected ${op}`);
      calls.push(params);
      if (answer instanceof Error) throw answer;
      return answer as T;
    },
    subscribe: () => Promise.reject(new Error("none")),
    handle: () => () => {},
  } as unknown as PageClient;
  return { host, calls };
}

async function renderChief(container: HTMLElement, host: PageClient) {
  const skills = new ChiefSkills(host, "c1");
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        chief={{ working: false, continueAvailable: false, onStop: () => {}, onContinue: () => {}, skills }}
      />,
    );
  });
  await settle();
  const field = container.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  const editable = container.querySelector<HTMLElement>(".ProseMirror")!;
  const type = async (text: string) => {
    await act(async () => field.insertTyped(text));
    await settle();
  };
  const key = async (name: string) => {
    await act(async () => {
      editable.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
    await settle();
  };
  const rows = () => [...container.querySelectorAll(".mt-slash-row .mt-slash-name")].map((row) => row.textContent);
  return { field, type, key, rows };
}

test("/ in a Chief chat lists its skills, filters as you type, and Tab picks one", async () => {
  const container = installDom();
  const { host, calls } = skillHost(SKILLS);
  const { field, type, key, rows } = await renderChief(container, host);
  expect(rows()).toEqual([]);
  await type("/");
  expect(rows()).toEqual(["/cmux-views", "/triage", "/emil-prototype", "/ai-sdk"]);
  expect(calls).toEqual([{ conversation: "c1" }]);
  // Where each comes from: the Chief's own, Claude's, a plugin's.
  expect([...container.querySelectorAll(".mt-slash-source")].map((cell) => cell.textContent)).toEqual([
    "Chief",
    "Chief",
    "Claude",
    "vercel",
  ]);
  await type("tri");
  expect(rows()).toEqual(["/triage"]);
  expect(calls.length).toBe(1);
  await key("Tab");
  expect(field.value()).toBe("/triage ");
  expect(rows()).toEqual([]);
});

test("Down then Return picks the chosen row; Escape closes the list", async () => {
  const container = installDom();
  const { field, type, key, rows } = await renderChief(container, skillHost(SKILLS).host);
  await type("/");
  await key("ArrowDown");
  expect(container.querySelector('.mt-slash-row[aria-selected="true"] .mt-slash-name')?.textContent).toBe("/triage");
  await key("Enter");
  expect(field.value()).toBe("/triage ");
  await act(async () => field.writeText("", 0, 0));
  await type("/");
  expect(rows().length).toBe(4);
  await key("Escape");
  expect(rows()).toEqual([]);
});

test("a path or a mid-message / is the person's text: no list", async () => {
  const container = installDom();
  const { type, rows } = await renderChief(container, skillHost(SKILLS).host);
  await type("/tmp");
  expect(rows()).toEqual([]);
  expect(container.querySelector(".mt-slash-menu")).toBeNull();
  expect(chiefSkillMatches(parseChiefSkills(SKILLS), { query: "tri", length: 4, leading: false })).toEqual([]);
});

test("a failed read says so, and a fresh / asks again", async () => {
  const container = installDom();
  const { host, calls } = skillHost(new Error("the Chief is not running"));
  const { field, type } = await renderChief(container, host);
  await type("/");
  expect(container.querySelector(".mt-slash-status")?.textContent).toBe(strings.t("home.compose.slash.failed"));
  await type("x");
  expect(calls.length).toBe(1);
  await act(async () => field.writeText("", 0, 0));
  await settle();
  await type("/");
  expect(calls.length).toBe(2);
});

test("a malformed row is left out, never the list", () => {
  expect(parseChiefSkills({ skills: [{ name: "/ok", description: 3 }, { description: "no name" }, null] })).toEqual([
    { name: "ok", description: "", source: "chief" },
  ]);
  expect(parseChiefSkills(null)).toEqual([]);
});
