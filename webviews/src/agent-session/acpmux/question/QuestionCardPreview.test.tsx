// An agent question whose options carry previews (Claude Code's AskUserQuestion `preview`: an ASCII
// mockup or code per option) shows the preview of the option the person is looking at: the hovered
// one while the pointer is on it, else the highlighted one. A preview the agent wrapped in a
// Markdown fence draws without the fence lines, as Claude Code draws it (Markdown in a monospace
// box), keeping every space so a mockup lines up. The preview sits beside a narrower list (the
// `question-preview-layout` experiment's default, `split`).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import type { AgentQuestion } from "./model";
import { QuestionCard } from "./QuestionCard";

const FIXTURE = fileURLToPath(
  new URL(
    "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-preview.json",
    import.meta.url,
  ),
);
const withPreviews = (): AgentQuestion => JSON.parse(fs.readFileSync(FIXTURE, "utf8"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(question: AgentQuestion): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(<QuestionCard question={question} onReply={() => undefined} />);
  });
  return container;
}

const previewLabel = (card: HTMLElement) => card.querySelector(".acpmux-question-preview-label")?.textContent;
const previewBody = (card: HTMLElement) => card.querySelector(".acpmux-question-preview pre")?.textContent;
const row = (card: HTMLElement, index: number) =>
  card.querySelector<HTMLElement>(`.acpmux-question-row[data-row="${index}"]`)!;

test("the native key target names the permission id when a card has a synthetic id", async () => {
  const question = withPreviews();
  question.id = "synthetic-conversation-question";
  question.source.permission = "daemon-permission";
  const container = await render(question);
  const card = container.querySelector<HTMLElement>(".acpmux-question")!;
  expect(card.dataset.cmuxQuestionSession).toBe(question.source.session);
  expect(card.dataset.cmuxQuestionId).toBe("daemon-permission");
  expect(card.dataset.cmuxQuestionEnterReply).toBeUndefined();
});

async function pointer(target: Element, type: "mouseover" | "mouseout", related: Element | null) {
  await act(async () => {
    target.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, relatedTarget: related }));
  });
}

test("the preview follows the hovered option, then returns to the highlighted one", async () => {
  const card = await render(withPreviews());
  expect(previewLabel(card)).toBe("Preview of Sidebar");
  await pointer(row(card, 1), "mouseover", null);
  expect(previewLabel(card)).toBe("Preview of Tabs");
  expect(previewBody(card)).toContain("┌ General ┬ Keys ┬ Agents");
  // The highlight did not move: only the pointer did.
  expect(row(card, 0).dataset.highlighted).toBe("true");
  await pointer(row(card, 1), "mouseout", card.ownerDocument.body);
  expect(previewLabel(card)).toBe("Preview of Sidebar");
});

test("a fenced preview draws without its fence lines and keeps its spacing", async () => {
  const question = withPreviews();
  const option = question.items[0]!.options[0]!;
  option.preview = { text: "```text\n  ┌──┐\n  │ok│\n```", format: "monospace" };
  const card = await render(question);
  expect(previewBody(card)).toBe("  ┌──┐\n  │ok│");
});

test("the preview sits beside a narrower list by default", async () => {
  const card = await render(withPreviews());
  expect(card.querySelector("fieldset")?.dataset.previewLayout).toBe("split");
});

test("a line holding an inline code span is content, not a fence", async () => {
  const question = withPreviews();
  question.items[0]!.options[0]!.preview = { text: "```literal``` stays\n~~~\nbody", format: "monospace" };
  const card = await render(question);
  expect(previewBody(card)).toBe("```literal``` stays\nbody");
});

test("the pointer on Other shows the highlighted option's preview, not the last hovered one", async () => {
  const card = await render(withPreviews());
  await pointer(row(card, 1), "mouseover", null);
  expect(previewLabel(card)).toBe("Preview of Tabs");
  // As a browser does when the pointer moves from one row to the next: out of Tabs, over Other.
  await pointer(row(card, 1), "mouseout", row(card, 3));
  await pointer(row(card, 3), "mouseover", row(card, 1));
  expect(previewLabel(card)).toBe("Preview of Sidebar");
});
