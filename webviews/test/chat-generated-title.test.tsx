// hq#2569 #8: a chat shows its first prompt only until its generated (or harness) title comes,
// then the sidebar row crossfades to it in the same slot. A user's own name always wins and
// swaps instantly.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { sessionEntry, sessionTitle, sessionTitleKind } from "../src/agent-session/acpmux/sessionList";

const base = { sessionId: "s1", name: "claude-sr", harness: "claude-sr", cwd: "/Users/you/src/cmux", updatedAt: 1 };

test("a first-prompt title is the prompt's until acpmux reports a real one", () => {
  const prompt = { ...base, title: "can you look at why the build fails", titleSource: "prompt" };
  expect(sessionTitleKind(prompt)).toBe("prompt");
  expect(sessionTitle(prompt)).toBe("can you look at why the build fails");
  expect(sessionTitleKind({ ...prompt, titleSource: "asked" })).toBe("prompt");
  for (const source of ["generated", "harness", "adopted", null, undefined])
    expect(sessionTitleKind({ ...base, title: "Build Failure on Main", titleSource: source })).toBe("title");
  expect(sessionTitleKind({ ...base, lastPrompt: "hello" })).toBe("prompt");
  expect(sessionTitleKind(base)).toBe("none");
});

test("the name the user gave wins over every title", () => {
  const named = { ...base, name: "Release notes", title: "Build Failure on Main", titleSource: "generated" };
  expect(sessionTitleKind(named)).toBe("name");
  expect(sessionTitle(named)).toBe("Release notes");
  expect(sessionEntry(named).titleKind).toBe("name");
});

const scope = globalThis as Record<string, unknown>;
const saved: (readonly [string, boolean, unknown])[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  // JSDOM has no Web Animations: a fade that never finishes keeps the leaving title in place.
  (window.Element.prototype as unknown as { animate: unknown }).animate = () => ({ onfinish: null, cancel() {} });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(window))
    if (
      /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
      !(key in scope)
    )
      replacements[key] = (window as unknown as Record<string, unknown>)[key];
  saved.push(...Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const));
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function row(summary: Record<string, unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { SessionSidebar } = await import("../src/agent-session/acpmux/SessionSidebar");
  root ??= createRoot(host);
  const sessions = [sessionEntry({ ...base, ...summary })];
  await act(async () => root!.render(<SessionSidebar sessions={sessions} onSelect={() => {}} />));
  return host.querySelector<HTMLElement>(".acpmux-session-row-title")!;
}

const leaving = () => host.querySelector<HTMLElement>("[data-sync-title=leaving]");
const current = () => host.querySelector<HTMLElement>("[data-sync-title=current]")?.textContent;

test("the generated title crossfades over the first prompt in the same slot", async () => {
  const slot = await row({ title: "fix the flaky upload test", titleSource: "asked" });
  expect(current()).toBe("fix the flaky upload test");
  expect(leaving()).toBeNull();

  const after = await row({ title: "Flaky Upload Test Fix", titleSource: "generated" });
  expect(after).toBe(slot);
  expect(current()).toBe("Flaky Upload Test Fix");
  // The prompt fades out on top of the new title, out of the flow: no layout shift.
  expect(leaving()?.textContent).toBe("fix the flaky upload test");
  expect(leaving()?.style.position).toBe("absolute");
});

test("the first prompt arriving and the user's own rename swap instantly", async () => {
  await row({});
  await row({ title: "fix the flaky upload test", titleSource: "prompt" });
  expect(leaving()).toBeNull();
  await row({ name: "Release notes", title: "fix the flaky upload test", titleSource: "prompt" });
  expect(current()).toBe("Release notes");
  expect(leaving()).toBeNull();
});
