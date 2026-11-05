// A question card with two questions can always be answered and sent (Leo 2026-10-20): he picked
// Other on "New tab pick", typed "idk", and the card's button was an empty, unlabeled, disabled
// pill that Enter did nothing for. The button says what it does: "Next" while another question
// still needs an answer, "Submit" once every question has one, and when it cannot submit it names
// the question still open. Enter in the Other field advances to that question, or submits on the
// last one, and Other with typed text counts as that question's answer.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AgentQuestion, QuestionReply } from "../src/agent-session/acpmux/question/model";
import { QuestionCard } from "../src/agent-session/acpmux/question/QuestionCard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "HTMLTextAreaElement",
  "Element",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLTextAreaElement: dom.window.HTMLTextAreaElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

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

const NEW_TAB = "When I open a new tab, which page should it show?";
const REFERENCES = "Which references should the plan cite?";

/// Leo's ask: two Claude Code questions, tabbed "New tab pick" | "References".
const question: AgentQuestion = {
  id: "perm_toolu_two",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_two",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "q0",
      header: "New tab pick",
      prompt: NEW_TAB,
      options: [
        { id: "Start page", label: "Start page" },
        { id: "Last folder", label: "Last folder" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
    {
      id: "q1",
      header: "References",
      prompt: REFERENCES,
      options: [
        { id: "Design doc", label: "Design doc" },
        { id: "None", label: "None" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

async function renderCard(): Promise<{ container: HTMLElement; replies: QuestionReply[] }> {
  const container = installDom();
  const replies: QuestionReply[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<QuestionCard question={question} onReply={(reply) => void replies.push(reply)} />);
  });
  return { container, replies };
}

const submitButton = (container: HTMLElement) => container.querySelector<HTMLButtonElement>(".acpmux-question-submit")!;
/// The button's words, without its keycap.
const buttonLabel = (container: HTMLElement) => {
  const button = submitButton(container).cloneNode(true) as HTMLElement;
  button.querySelector(".acpmux-keycap")?.remove();
  return button.textContent?.trim() ?? "";
};
const activeTab = (container: HTMLElement) =>
  container.querySelector(".acpmux-question-tab[aria-current=step]")?.textContent?.trim();
const prompt = (container: HTMLElement) => container.querySelector(".acpmux-question-prompt")?.textContent?.trim();

async function click(element: Element | null | undefined) {
  if (!element) throw new Error("nothing to click");
  await act(async () => {
    (element as HTMLElement).click();
  });
}

/// Picks Other on the active question and types `text` into its field, as a person does.
async function answerOther(container: HTMLElement, text: string) {
  await click(container.querySelector(".acpmux-question-other-choice"));
  const field = container.querySelector<HTMLTextAreaElement>(".acpmux-question-other textarea");
  if (!field) throw new Error("the Other row did not turn into a text field");
  await act(async () => {
    const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setValue.call(field, text);
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  return field;
}

async function pressEnter(target: Element, init: KeyboardEventInit = {}) {
  await act(async () => {
    target.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...init }),
    );
  });
}

test("Other with typed text answers a question: the button says Next and Enter goes to the open question", async () => {
  const { container, replies } = await renderCard();
  expect(activeTab(container)).toBe("New tab pick");

  const field = await answerOther(container, "idk");
  // The button is labeled and pressable: another question still needs an answer.
  expect(buttonLabel(container)).toBe("Next");
  expect(submitButton(container).disabled).toBe(false);
  // The New tab pick tab shows it has an answer.
  expect(container.querySelector(".acpmux-question-tab")?.hasAttribute("data-answered")).toBe(true);

  await pressEnter(field);
  expect(activeTab(container)).toBe("References");
  expect(prompt(container)).toBe(REFERENCES);
  expect(replies).toEqual([]);

  // On the last open question the button says Submit and names what it waits for.
  expect(buttonLabel(container)).toBe("Submit");
  expect(container.querySelector(".acpmux-question-hint")?.textContent?.trim()).toBe("Answer References to submit");

  // Enter on the highlighted row answers References, then sends both answers.
  await pressEnter(container.querySelector(".acpmux-question-row[data-highlighted]")!);
  expect(replies).toEqual([
    {
      session: "sess_claude_1",
      permissionId: "perm_toolu_two",
      optionId: "allow_once",
      answers: { [NEW_TAB]: "idk", [REFERENCES]: "Design doc" },
    },
  ]);
});

test("Enter in the Other field of the last open question submits the card", async () => {
  const { container, replies } = await renderCard();
  // References first: a click answers it and stays there (Submit names the one still open), then
  // its tab goes back to the open one.
  await click(container.querySelectorAll(".acpmux-question-tab")[1]);
  await click(container.querySelector(".acpmux-question-row[data-row='1']"));
  expect(activeTab(container)).toBe("References");
  expect(replies).toEqual([]);
  expect(container.querySelector(".acpmux-question-hint")?.textContent?.trim()).toBe("Answer New tab pick to submit");
  await click(container.querySelectorAll(".acpmux-question-tab")[0]);
  expect(activeTab(container)).toBe("New tab pick");
  // The tab hands the keyboard to the question's rows, so the keys answer it.
  expect(dom!.window.document.activeElement?.closest(".acpmux-question-rows")).not.toBeNull();

  const field = await answerOther(container, "idk");
  expect(buttonLabel(container)).toBe("Submit");
  expect(submitButton(container).disabled).toBe(false);
  expect(container.querySelector(".acpmux-question-hint")).toBeNull();

  await pressEnter(field);
  expect(replies).toEqual([
    {
      session: "sess_claude_1",
      permissionId: "perm_toolu_two",
      optionId: "allow_once",
      answers: { [NEW_TAB]: "idk", [REFERENCES]: "None" },
    },
  ]);
});

test("Next moves tab by tab before anything is answered, and the button is never silent", async () => {
  const { container, replies } = await renderCard();
  expect(buttonLabel(container)).toBe("Next");
  expect(submitButton(container).disabled).toBe(false);
  await click(submitButton(container));
  expect(activeTab(container)).toBe("References");
  // Nothing answered yet: Submit waits, and says for which question.
  expect(buttonLabel(container)).toBe("Submit");
  expect(container.querySelector(".acpmux-question-hint")?.textContent?.trim()).toBe(
    "Answer New tab pick and References to submit",
  );
  expect(replies).toEqual([]);
});

test("the button's label is drawn in a color the theme always sets", () => {
  // --agent-page-bg is transparent in a translucent window, which drew the label invisible.
  const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");
  const rule = css.match(/\.acpmux-question-submit\{[^}]*\}/)?.[0] ?? "";
  expect(rule).not.toBe("");
  expect(rule).not.toContain("--agent-page-bg");
});
