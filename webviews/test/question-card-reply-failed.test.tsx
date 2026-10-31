// A refused answer shows one message, never two glued together (Leo's live report 2026-10-21):
// the card said "Couldn’t send your answer. Try again. approve this on the Mac app: allowing a
// permission is accepted only from the cmux app, ..." because it appended acpmux's English
// refusal, meant for its CLI, to its own sentence. Now the card's sentence always leads; the
// pane's own words for a refusal it knows (a code), or a message already in the person's language
// (the Swift host's or the pane's own), follow it; and acpmux's English never shows: such a
// failure reads only "Couldn’t send your answer. Try again."
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../src/agent-session/acpmux/i18n";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
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
  "HTMLTextAreaElement",
  "Element",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    HTMLTextAreaElement: dom.window.HTMLTextAreaElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

type NativeReplyClient = {
  receive(raw: string): void;
  rejectPending(): void;
  pending: Map<string | number, unknown>;
};
const nativeClients: NativeReplyClient[] = [];

afterEach(async () => {
  await act(async () => {
    for (const client of nativeClients.splice(0)) client.rejectPending();
  });
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
  // #23890 may give this reason its own words after the card's sentence; never acpmux's.
  expect(text.startsWith(translate("question.replyFailed"))).toBe(true);
  expect(text).not.toContain("approve this on the Mac app");
  expect(text).not.toContain("never from the CLI");
});

test("acpmux's English for a refusal the pane has no words for shows only the card's sentence", async () => {
  const text = await refusedWith(
    new AcpmuxRpcError({
      code: -32000,
      message: "session sess_claude_1 has no pending permission perm_toolu_one",
      data: { reason: "permission.not_pending" },
    }),
  );
  expect(text).toBe(translate("question.replyFailed"));
});

test("a failure the pane has no words for shows only the card's own sentence", async () => {
  expect(await refusedWith(new Error("session sess_claude_1 has no pending permission perm_toolu_one"))).toBe(
    translate("question.replyFailed"),
  );
});

test("a refusal the pane has words for follows the card's sentence", async () => {
  const text = await refusedWith(
    Object.assign(new Error("not in this pane"), { code: "transport.session_not_in_pane" }),
  );
  expect(text).toBe(`${translate("question.replyFailed")} ${translate("transport.sessionNotInPane")}`);
});

test("acpmux's full_access_off refusal reads as the card's sentence, then the pane's words", async () => {
  const text = await refusedWith(
    new AcpmuxRpcError({
      code: -32000,
      message: "full access is off for this session",
      data: { reason: "full_access_off" },
    }),
  );
  expect(text).toBe(`${translate("question.replyFailed")} ${translate("transport.fullAccessOff")}`);
});

test("the app's own message, already in the person's language, follows the card's sentence", async () => {
  const message = "acpmux is not running. Open a new agent chat to start it.";
  expect(await refusedWith(new NativeError({ userMessage: message }))).toBe(
    `${translate("question.replyFailed")} ${message}`,
  );
});

test("the pane's own words for a lost connection follow the card's sentence", async () => {
  const lost = Object.assign(new Error(translate("error.notOpen")), {
    code: "native.not_connected",
    origin: "native",
  });
  expect(await refusedWith(lost)).toBe(`${translate("question.replyFailed")} ${translate("error.notOpen")}`);
});

// Exercise the real client's RPC correlation and the real card together. The isolated listener
// prevented the normal onReply handler; only the native announcement and its string-id reply run.
async function nativeReturnCard() {
  const container = installDom();
  let webReplies = 0;
  const ask: AgentQuestion = {
    ...question,
    id: "synthetic-question-row",
    items: question.items.map((item) => ({ ...item, allowsOther: true })),
  };
  await act(async () => {
    root = createRoot(container);
    root.render(<QuestionCard question={ask} onReply={() => void webReplies++} />);
  });
  await act(async () => container.querySelector<HTMLElement>(".acpmux-question-other-choice")!.click());
  const field = container.querySelector<HTMLTextAreaElement>(".acpmux-question-other textarea")!;
  await act(async () => {
    const setValue = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")!.set!;
    setValue.call(field, "x".repeat(4097));
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    field.focus();
  });
  const client = Object.assign(Object.create(AcpmuxDirectClient.prototype), {
    pending: new Map(),
    wire: { received: () => undefined },
  }) as NativeReplyClient;
  nativeClients.push(client);
  const card = container.querySelector<HTMLElement>(".acpmux-question")!;
  const announce = async (id: string, sessionId = question.source.session) => {
    await act(async () =>
      client.receive(
        JSON.stringify({
          method: "_cmux/question_key_request",
          params: { id, sessionId, permissionId: question.source.permission },
        }),
      ),
    );
  };
  const answer = async (id: string, error?: unknown) => {
    await act(async () => client.receive(JSON.stringify({ id, ...(error ? { error } : { result: {} }) })));
  };
  return { container, card, field, client, announce, answer, webReplies: () => webReplies };
}

test.each([
  [
    "local submit",
    { code: -32602, message: "invalid answer", data: { code: "transport.intent_invalid" } },
    "transport.intentInvalid",
  ],
  [
    "daemon",
    {
      code: -32000,
      message: "approve this on the Mac app",
      data: { reason: "permission.person_required" },
    },
    "transport.personRequired",
  ],
] as const)("a native Return %s refusal reaches the card and permits retry", async (_source, error, reason) => {
  const { container, card, field, client, announce, answer, webReplies } = await nativeReturnCard();
  const capturedReply = card.dataset.cmuxQuestionEnterReply;
  const editing = field.closest(".acpmux-question-other");
  await announce("question-key-first");
  expect(card.getAttribute("aria-busy")).toBe("true");
  // Pending feedback must preserve the DOM evidence until the native host has redeemed it.
  expect(container.querySelector("textarea")).toBe(field);
  expect(dom!.window.document.activeElement).toBe(field);
  expect(field.disabled).toBe(false);
  expect(editing?.getAttribute("data-row-editing")).toBe("true");
  expect(card.dataset.cmuxQuestionEnterReply).toBe(capturedReply);
  await answer("question-key-first", error);
  expect(container.querySelector("[role=alert]")?.textContent?.trim()).toBe(
    `${translate("question.replyFailed")} ${translate(reason)}`,
  );
  expect(card.hasAttribute("aria-busy")).toBe(false);
  expect(field.value).toBe("x".repeat(4097));
  expect(field.disabled).toBe(false);
  expect(client.pending.size).toBe(0);
  // The host may have injected the same refusal before its submit completion fallback.
  await answer("question-key-first", error);
  await announce("question-key-retry");
  expect(container.querySelector("[role=alert]")).toBeNull();
  expect(card.getAttribute("aria-busy")).toBe("true");
  await answer("question-key-retry");
  expect(card.getAttribute("aria-busy")).toBe("true");
  expect(container.querySelector<HTMLButtonElement>(".acpmux-question-submit")?.disabled).toBe(true);
  expect(webReplies()).toBe(0);
  expect(client.pending.size).toBe(0);
});

test("a native Return interrupted by disconnect shows the card's retry error", async () => {
  const { container, card, field, client, announce } = await nativeReturnCard();
  await announce("question-key-disconnect");
  await act(async () => client.rejectPending());
  expect(container.querySelector("[role=alert]")?.textContent?.trim()).toBe(
    `${translate("question.replyFailed")} ${translate("error.interrupted")}`,
  );
  expect(card.hasAttribute("aria-busy")).toBe(false);
  expect(field.disabled).toBe(false);
  expect(client.pending.size).toBe(0);
});

test("a native Return result for another session cannot put this question in error", async () => {
  const { container, card, announce, answer } = await nativeReturnCard();
  await announce("question-key-other-session", "other-session");
  await answer("question-key-other-session", {
    code: -32602,
    data: { code: "transport.intent_invalid" },
  });
  expect(container.querySelector("[role=alert]")).toBeNull();
  expect(card.hasAttribute("aria-busy")).toBe(false);
});

test("a late native Return failure cannot overwrite a newer request's state", async () => {
  const { container, card, announce, answer } = await nativeReturnCard();
  await announce("question-key-old-connection");
  await announce("question-key-new-connection");
  await answer("question-key-old-connection", {
    code: -32602,
    data: { code: "transport.intent_invalid" },
  });
  expect(container.querySelector("[role=alert]")).toBeNull();
  expect(card.getAttribute("aria-busy")).toBe("true");
  await answer("question-key-new-connection");
  expect(container.querySelector("[role=alert]")).toBeNull();
  expect(container.querySelector<HTMLButtonElement>(".acpmux-question-submit")?.disabled).toBe(true);
});
