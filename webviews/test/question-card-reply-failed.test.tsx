// A refused answer shows one message, never two glued together (Leo's live report 2026-10-21):
// the card said "Couldn’t send your answer. Try again. approve this on the Mac app: allowing a
// permission is accepted only from the cmux app, ..." because it appended acpmux's English
// refusal, meant for its CLI, to its own sentence. Now an error the pane has words for (a refusal
// with a code) shows those words alone, and any other failure shows only "Couldn’t send your
// answer. Try again.", never the daemon's message.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import type { AgentQuestion } from "../src/agent-session/acpmux/question/model";
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
  "HTMLInputElement",
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
    HTMLInputElement: dom.window.HTMLInputElement,
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

const question: AgentQuestion = {
  id: "perm_toolu_one",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_one",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "q0",
      header: "Database",
      prompt: "Which database should the service use?",
      options: [
        { id: "Postgres", label: "Postgres" },
        { id: "SQLite", label: "SQLite" },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};

/// Renders the card with a host that refuses every reply with `error`, picks the first option
/// (which answers the only question) and returns the card's error line once it shows.
async function refusedWith(error: unknown): Promise<string> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<QuestionCard question={question} onReply={() => Promise.reject(error)} />);
  });
  await act(async () => {
    container.querySelector<HTMLElement>(".acpmux-question-row[data-row='0']")!.click();
  });
  const submit = container.querySelector<HTMLButtonElement>(".acpmux-question-submit");
  if (submit && !submit.disabled)
    await act(async () => {
      submit.click();
    });
  const alert = container.querySelector("[role=alert]");
  if (!alert) throw new Error("the card shows no error after a refused reply");
  return alert.textContent?.trim() ?? "";
}

test("acpmux's English refusal is never appended to the card's sentence", async () => {
  const text = await refusedWith(
    new AcpmuxRpcError({
      code: -32000,
      message:
        "approve this on the Mac app: allowing a permission is accepted only from the cmux app, never from the CLI, a script or an agent",
      data: { reason: "permission.person_required" },
    }),
  );
  expect(text).not.toContain("approve this on the Mac app");
  expect(text).not.toContain("never from the CLI");
});

test("a failure the pane has no words for shows only the card's own sentence", async () => {
  expect(await refusedWith(new Error("session sess_claude_1 has no pending permission perm_toolu_one"))).toBe(
    translate("question.replyFailed"),
  );
});

test("a refusal the pane has words for shows those words alone", async () => {
  const text = await refusedWith(
    Object.assign(new Error("not in this pane"), { code: "transport.session_not_in_pane" }),
  );
  expect(text).toBe(translate("transport.sessionNotInPane"));
});
