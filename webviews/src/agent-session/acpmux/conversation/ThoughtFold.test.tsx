// l10n-allow-file: test fixture thoughts, not shipped UI.
// The brain thought style (Debug choice agentPane.debug.thoughtStyle, thoughtStyle.ts): a thought,
// and a note the agent wrote between steps of a finished turn, is one quiet line (a brain and the
// thought's first line) that opens to "Thoughts" over the whole text. Unset, both draw as before.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { ThoughtRow } from "./ThoughtRow";
import { thoughtLine } from "./ThoughtFold";
import { isThoughtNote, thoughtStyle } from "./thoughtStyle";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const style = { ...thoughtStyle };

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  Object.assign(thoughtStyle, style);
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const TEXT = "**Checking the retry path**\nThe upload is a single fetch with no retry.";

function render(id: string) {
  act(() => {
    root ??= createRoot(container);
    root.render(<ThoughtRow id={id} item={{ kind: "thought", text: TEXT }} />);
  });
}
const toggle = () => container.querySelector<HTMLButtonElement>("button.cv-thought-fold");

test("the style is today's unless the page says brain", () => {
  expect(thoughtStyle.current()).toBe("plain");
  dom!.window.document.documentElement.setAttribute("data-thought-style", "brain");
  expect(thoughtStyle.current()).toBe("brain");
});

test("plain, a thought draws as before: no brain line", () => {
  render("plain:0");
  expect(toggle()).toBeNull();
  expect(container.querySelector(".cv-thought__text")?.textContent).toBe(TEXT);
});

test("brain, a thought is one closed line with its first line; opened it reads Thoughts over the text", () => {
  thoughtStyle.current = () => "brain";
  render("brain:0");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".cv-thought-fold__line")?.textContent).toBe("Checking the retry path");
  expect(container.querySelector(".cv-thought-fold__body")).toBeNull();
  act(() => toggle()!.click());
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".cv-thought-fold__line")?.textContent).toBe("Thoughts");
  expect(container.querySelector(".cv-thought-fold__body")?.textContent).toContain("single fetch with no retry");
});

test("the reader's open survives the row unmounting", () => {
  thoughtStyle.current = () => "brain";
  render("brain:keep");
  act(() => toggle()!.click());
  act(() => root!.unmount());
  root = undefined;
  render("brain:keep");
  expect(toggle()?.getAttribute("aria-expanded")).toBe("true");
});

test("the line skips a code fence and drops Markdown marks", () => {
  expect(thoughtLine("```ts\nconst a = 1;\n```")).toBe("const a = 1;");
  expect(thoughtLine("\n## Plan\nthen")).toBe("Plan");
  expect(thoughtLine("- use `withRetry` from [retry](retry.ts)")).toBe("use withRetry from retry");
  expect(thoughtLine("   \n")).toBe("");
});

test("only a reply copied under an open Worked for is a thought note, and only in brain", () => {
  const note: AcpmuxRow = { id: "a1", version: 1, at: 0, kind: "assistant", text: "Next.", settled: true };
  const answer: AcpmuxRow = { ...note, settled: undefined };
  expect(isThoughtNote(note)).toBe(false);
  thoughtStyle.current = () => "brain";
  expect(isThoughtNote(note)).toBe(true);
  expect(isThoughtNote(answer)).toBe(false);
  expect(isThoughtNote({ ...note, kind: "activity" })).toBe(false);
});
