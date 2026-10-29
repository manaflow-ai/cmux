// A click on a question card's option chooses it and never sends it (Leo 2026-10-24, on the folder
// trust card: "just clicking it directly just automatically sends the input. So it makes the skip
// and submit buttons redundant, which is a bit weird. I feel like that shouldn't be the case").
// Submit or ⌘↩ sends the choice, Skip declines, Enter sends the highlighted row, and a double-click
// on a single-choice option chooses and sends it. On a single-choice question the arrows move the
// choice with the highlight, so Submit sends the row the person sees. Multi-select is unchanged.
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

const PROMPT = "Which auth should the app use?";
/// A Claude Code AskUserQuestion with one single-choice question.
const askSingle: AgentQuestion = {
  id: "perm_toolu_single",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_single",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "q0",
      prompt: PROMPT,
      options: [
        { id: "Passkeys", label: "Passkeys" },
        { id: "API keys", label: "API keys" },
        { id: "OAuth", label: "OAuth" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

const askMulti: AgentQuestion = {
  ...askSingle,
  id: "perm_toolu_multi",
  source: { ...askSingle.source, permission: "perm_toolu_multi" },
  items: [{ ...askSingle.items[0]!, multiSelect: true }],
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

const row = (container: HTMLElement, label: string) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-question-row")].find((each) =>
    each.querySelector(".acpmux-question-label")?.textContent?.includes(label),
  )!;
const submit = (container: HTMLElement) => container.querySelector<HTMLButtonElement>(".acpmux-question-submit")!;
const checked = (container: HTMLElement) =>
  [...container.querySelectorAll(".acpmux-question-row[aria-checked=true] .acpmux-question-label")].map(
    (each) => each.textContent,
  );

async function click(element: HTMLElement) {
  await act(async () => element.click());
}
async function doubleClick(element: HTMLElement) {
  await act(async () => {
    element.click();
    element.click();
    element.dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true }));
  });
}
async function press(target: Element, key: string, init: KeyboardEventInit = {}) {
  await act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

test("one click on a folder trust option selects it; Submit sends it", async () => {
  const { container, replies } = await renderCard(folderTrust);
  expect(submit(container).disabled).toBe(true);

  await click(row(container, "Trust folder"));
  expect(replies).toEqual([]);
  expect(checked(container)).toEqual(["Trust folder"]);
  expect(submit(container).disabled).toBe(false);

  // A second pick changes the choice, still without sending.
  await click(row(container, "Not now"));
  await click(row(container, "Trust folder"));
  expect(replies).toEqual([]);

  await click(submit(container));
  expect(replies).toEqual([{ session: "sess_claude_1", permissionId: "perm_trust_1", optionId: "trust" }]);
});

test("Skip declines after a pick, so it is never redundant", async () => {
  const { container, replies } = await renderCard(folderTrust);
  await click(row(container, "Trust folder"));
  await click(container.querySelector<HTMLElement>(".acpmux-question-skip")!);
  expect(replies).toEqual([{ session: "sess_claude_1", permissionId: "perm_trust_1", optionId: "not_now" }]);
});

test("one click on an AskUserQuestion option selects it; ⌘↩ sends it", async () => {
  const { container, replies } = await renderCard(askSingle);
  await click(row(container, "API keys"));
  expect(replies).toEqual([]);
  await press(row(container, "API keys"), "Enter", { metaKey: true });
  expect(replies).toEqual([
    {
      session: "sess_claude_1",
      permissionId: "perm_toolu_single",
      optionId: "allow_once",
      answers: { [PROMPT]: "API keys" },
    },
  ]);
});

test("the arrows move the choice, and Submit sends the row the person sees", async () => {
  const { container, replies } = await renderCard(askSingle);
  await click(row(container, "Passkeys"));
  await press(row(container, "Passkeys"), "ArrowDown");
  expect(checked(container)).toEqual(["API keys"]);
  expect(replies).toEqual([]);
  await click(submit(container));
  expect(replies[0]?.answers).toEqual({ [PROMPT]: "API keys" });
});

test("arrowing onto Other leaves no option chosen, so ⌘↩ opens the field instead of sending", async () => {
  const { container, replies } = await renderCard(askSingle);
  await click(row(container, "API keys"));
  await press(row(container, "API keys"), "ArrowDown");
  await press(row(container, "OAuth"), "ArrowDown");
  expect(checked(container)).toEqual([]);
  expect(submit(container).disabled).toBe(true);
  await press(container.querySelector(".acpmux-question-other-choice")!, "Enter", { metaKey: true });
  expect(replies).toEqual([]);
  expect(container.querySelector(".acpmux-question-other textarea")).not.toBeNull();
});

test("an option clicked while the Other field is open closes the field and takes the keyboard", async () => {
  const { container, replies } = await renderCard(askSingle);
  await click(container.querySelector<HTMLElement>(".acpmux-question-other-choice")!);
  const field = container.querySelector<HTMLTextAreaElement>(".acpmux-question-other textarea")!;
  await act(async () => {
    const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setValue.call(field, "custom");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await click(row(container, "Passkeys"));
  expect(container.querySelector(".acpmux-question-other textarea")).toBeNull();
  expect(dom!.window.document.activeElement).toBe(row(container, "Passkeys"));
  expect(checked(container)).toEqual(["Passkeys"]);
  await press(row(container, "Passkeys"), "Enter", { metaKey: true });
  expect(replies[0]?.answers).toEqual({ [PROMPT]: "Passkeys" });
});

test("Enter sends the highlighted row", async () => {
  const { container, replies } = await renderCard(askSingle);
  await press(row(container, "Passkeys"), "ArrowDown");
  await press(row(container, "API keys"), "Enter");
  expect(replies[0]?.answers).toEqual({ [PROMPT]: "API keys" });
});

test("a double-click on a single-choice option sends it once", async () => {
  const { container, replies } = await renderCard(folderTrust);
  await doubleClick(row(container, "Trust folder"));
  expect(replies).toEqual([{ session: "sess_claude_1", permissionId: "perm_trust_1", optionId: "trust" }]);
});

test("multi-select is unchanged: clicks toggle, a double-click sends nothing, Submit sends the set", async () => {
  const { container, replies } = await renderCard(askMulti);
  await click(row(container, "Passkeys"));
  await click(row(container, "OAuth"));
  await doubleClick(row(container, "API keys"));
  expect(replies).toEqual([]);
  expect(checked(container)).toEqual(["Passkeys", "OAuth"]);
  await press(row(container, "API keys"), "ArrowUp");
  expect(checked(container)).toEqual(["Passkeys", "OAuth"]);
  await click(submit(container));
  expect(replies.length).toBe(1);
});
