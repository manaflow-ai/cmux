// A yes-or-no ask draws as ChatGPT's consent card (Leo's 2026-10-29 reference, beside Codex's
// environment cards): the question, one muted line of what Allow does, and two buttons with their
// keys, "Not now esc" and a filled "Trust folder ↩". The folder trust card has no option list, Skip or
// Submit any more (Leo 2026-10-24: "it makes the skip and submit buttons redundant"). Any other
// ask keeps its list, and its Skip shows its esc key.
import { afterEach, expect, test } from "bun:test";
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
  "IS_REACT_ACT_ENVIRONMENT",
];

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

/// The card acpmux raises before a sub-session starts in a folder nobody trusted (hub/trust_wait.rs).
const folderTrust: AgentQuestion = {
  id: "perm_trust_1",
  source: {
    harness: "acp",
    session: "sess_claude_1",
    permission: "perm_trust_1",
    agentName: "cmux",
    answerOption: "trust",
    rejectOption: "not_now",
  },
  items: [
    {
      id: "q0",
      header: "Folder trust",
      prompt: "update-toggle wants to work in /private/tmp/claude-sr2/lanes. Do you trust this folder?",
      options: [
        { id: "trust", label: "Trust folder", detail: "cmux stops asking about this folder." },
        { id: "not_now", label: "Not now", detail: "The sub-session does not start." },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};
const TRUST = { session: "sess_claude_1", permissionId: "perm_trust_1", optionId: "trust" };
const NOT_NOW = { session: "sess_claude_1", permissionId: "perm_trust_1", optionId: "not_now" };

/// A two-option AskUserQuestion: its options are the agent's answers, not the permission's own.
const askTwo: AgentQuestion = {
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
      prompt: "Ship it?",
      options: [
        { id: "Yes", label: "Yes" },
        { id: "No", label: "No" },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};

async function renderCard(question: AgentQuestion) {
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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  const replies: QuestionReply[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<QuestionCard question={question} onReply={(reply) => void replies.push(reply)} />);
  });
  return { container, replies };
}

const button = (container: HTMLElement, selector: string) => container.querySelector<HTMLButtonElement>(selector)!;
const text = (element: Element | null) => element?.textContent?.replace(/\s+/g, " ").trim();
/// A button's label and the key drawn in it.
const labelAndKey = (element: Element) => {
  const key = element.querySelector("kbd");
  return [
    text(element)
      ?.slice(0, -(key?.textContent?.length ?? 0))
      .trim(),
    text(key),
  ];
};

async function press(target: Element, key: string, init: KeyboardEventInit = {}) {
  await act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

test("the folder trust card is a consent: the question, one scope line, Not now esc and Trust folder ↩", async () => {
  const { container } = await renderCard(folderTrust);
  expect(container.querySelector(".acpmux-question[data-consent]")).not.toBeNull();
  expect(container.querySelectorAll(".acpmux-question-row").length).toBe(0);
  expect(text(container.querySelector(".acpmux-question-prompt"))).toContain("Do you trust this folder?");
  expect(text(container.querySelector(".acpmux-question-scope"))).toBe("cmux stops asking about this folder.");
  expect(labelAndKey(button(container, ".acpmux-question-skip"))).toEqual(["Not now", "esc"]);
  expect(labelAndKey(button(container, ".acpmux-question-submit"))).toEqual(["Trust folder", "↩"]);
  expect(button(container, ".acpmux-question-submit").getAttribute("aria-keyshortcuts")).toBe("Enter");
  expect(button(container, ".acpmux-question-skip").getAttribute("aria-keyshortcuts")).toBe("Escape");
});

test("Trust folder sends trust once; Not now declines", async () => {
  const first = await renderCard(folderTrust);
  await act(async () => {
    button(first.container, ".acpmux-question-submit").click();
    button(first.container, ".acpmux-question-submit").click();
  });
  expect(first.replies).toEqual([TRUST]);
  await act(async () => root!.unmount());
  root = undefined;

  const second = await renderCard(folderTrust);
  await act(async () => button(second.container, ".acpmux-question-skip").click());
  expect(second.replies).toEqual([NOT_NOW]);
});

test("Return trusts and Esc declines from anywhere in the consent", async () => {
  const yes = await renderCard(folderTrust);
  await press(yes.container.querySelector(".acpmux-question")!, "Enter");
  expect(yes.replies).toEqual([TRUST]);
  await act(async () => root!.unmount());
  root = undefined;

  const no = await renderCard(folderTrust);
  await press(button(no.container, ".acpmux-question-submit"), "Escape");
  expect(no.replies).toEqual([NOT_NOW]);
});

test("⌘↩ trusts, and Return on a focused Not now is left to the button, never Allow", async () => {
  const yes = await renderCard(folderTrust);
  await press(yes.container.querySelector(".acpmux-question")!, "Enter", { metaKey: true });
  expect(yes.replies).toEqual([TRUST]);
  await act(async () => root!.unmount());
  root = undefined;

  const no = await renderCard(folderTrust);
  const notNow = button(no.container, ".acpmux-question-skip");
  const event = new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  await act(async () => {
    notNow.dispatchEvent(event);
  });
  expect(event.defaultPrevented).toBe(false);
  expect(no.replies).toEqual([]);
});

test("a consent consumes the list's number and arrow keys and picks nothing", async () => {
  const { container, replies } = await renderCard(folderTrust);
  const card = container.querySelector(".acpmux-question")!;
  for (const key of ["1", "2", "ArrowDown", "ArrowUp"]) {
    const event = new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
    await act(async () => {
      card.dispatchEvent(event);
    });
    // Consumed, so the composer's type-to-focus never inserts the digit into the draft.
    expect(event.defaultPrevented).toBe(true);
  }
  expect(replies).toEqual([]);
});

test("a two-option AskUserQuestion keeps its list, Skip and Submit, and Skip shows esc", async () => {
  const { container, replies } = await renderCard(askTwo);
  expect(container.querySelector(".acpmux-question[data-consent]")).toBeNull();
  expect(container.querySelectorAll(".acpmux-question-row").length).toBe(2);
  expect(labelAndKey(button(container, ".acpmux-question-skip"))).toEqual(["Skip", "esc"]);
  expect(button(container, ".acpmux-question-skip").getAttribute("aria-keyshortcuts")).toBe("Escape");
  expect(replies).toEqual([]);
});
