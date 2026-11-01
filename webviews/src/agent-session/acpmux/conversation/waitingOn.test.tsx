// l10n-allow-file: test fixture questions, not shipped UI.
// Leo 2026-10-21: a new chat read "Thinking" forever while the agent waited on the folder's trust
// question, so he waited on an agent that waited on him. While an ask above the composer waits on
// the person, the running turn's line says so: never "Thinking", never a ticking "Working for".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { questionFromPermission } from "../question/model";
import { Thinking } from "./Thinking";
import { chatWaitsOn, WaitingOnContext, type WaitingOn, waitingOn } from "./waitingOn";
import { WorkingFor } from "./WorkingFor";

const cwd = "/Users/you/Projects/demo-app";
const none = { permission: false, secret: false, question: false };

function within(waiting: WaitingOn | undefined, line: React.ReactElement) {
  return renderToStaticMarkup(<WaitingOnContext.Provider value={waiting}>{line}</WaitingOnContext.Provider>);
}

test("a pending trust question never renders as thinking", () => {
  const waiting = waitingOn({ ...none, trust: { cwd, state: "ask" } });
  expect(waiting).toBe("trust");
  const html = within(waiting, <Thinking />);
  expect(html).toContain(translate("turn.waiting.trust"));
  expect(html).not.toContain(`>${translate("thinking")}<`);
  // While its agent starts too: the prompt waits on the person.
  const starting = within(waiting, <Thinking starting />);
  expect(starting).toContain(translate("turn.waiting.trust"));
});

test("a running turn that waits on a permission shows no clock", () => {
  const row = { id: "working-1", version: 1, at: 0, kind: "working", doing: "Bash" } as AcpmuxRow;
  const html = within("permission", <WorkingFor row={row} now={() => 125_000} />);
  expect(html).toContain(translate("turn.waiting.permission"));
  expect(html).not.toContain("2m");
  expect(html).not.toContain("Bash");
  // Without a wait the same line ticks and names the call, as before.
  const running = within(undefined, <WorkingFor row={row} now={() => 125_000} />);
  expect(running).toContain("Bash");
  expect(running).not.toContain(translate("turn.waiting.permission"));
});

test("the trust question comes first, then the other asks in the stack's order", () => {
  expect(waitingOn({ ...none, trust: { cwd, state: "failed" }, permission: true })).toBe("trust");
  expect(waitingOn({ ...none, trust: { cwd, state: "remote" } })).toBe("trustRemote");
  // An answered folder waits on nobody, and a decided Don't trust runs no turn to wait in.
  expect(waitingOn({ ...none, trust: { cwd, state: "decided", level: "trusted" } })).toBeUndefined();
  expect(waitingOn({ ...none, trust: { cwd, state: "decided", level: "untrusted" } })).toBeUndefined();
  expect(waitingOn({ ...none, permission: true, secret: true })).toBe("permission");
  expect(waitingOn({ ...none, secret: true, question: true })).toBe("secret");
  expect(waitingOn({ ...none, question: true })).toBe("question");
  expect(waitingOn(none)).toBeUndefined();
});

// Review of #23119: the line must never claim a wait that is over or out of sight.
/// A pending tool permission (Bash, an edit): no question on it.
const toolAsk = {};
const chat = {
  holdsAsks: false,
  trustBlocks: false,
  isWorking: true,
  secret: false,
  cards: [] as { state: string }[],
};

test("an answered permission group is a receipt, not a wait", () => {
  expect(chatWaitsOn({ ...chat, permissionGroups: [{ state: "resolved" }, { state: "cancelled" }] })).toBeUndefined();
  expect(chatWaitsOn({ ...chat, permissionGroups: [{ state: "resolved" }, { state: "pending" }] })).toBe("permission");
  expect(chatWaitsOn({ ...chat, permissionGroups: [{ state: "collecting" }] })).toBe("permission");
});

test("a card at work asks nothing; one that asks does", () => {
  expect(chatWaitsOn({ ...chat, cards: [{ state: "working" }, { state: "failed" }] })).toBeUndefined();
  expect(chatWaitsOn({ ...chat, cards: [{ state: "working" }, { state: "ask" }] })).toBe("question");
});

test("asks the trust question holds out of the stack are not named", () => {
  const held = { ...chat, holdsAsks: true, individualPermission: toolAsk, secret: true, cards: [{ state: "ask" }] };
  expect(chatWaitsOn(held)).toBeUndefined();
  expect(chatWaitsOn({ ...chat, trustBlocks: true, secret: true })).toBeUndefined();
});

test("trust holds new prompts, not a running turn", () => {
  const trust = { cwd, state: "ask" as const };
  expect(chatWaitsOn({ ...chat, trust, holdsAsks: true })).toBeUndefined();
  expect(chatWaitsOn({ ...chat, trust, holdsAsks: true, isWorking: false })).toBe("trust");
});

// A stalled model (an OpenCode free model) left "Thinking" up forever: past acpmux's silentTurnMs
// with nothing from the agent, the line says the model has not answered, after any ask the person
// can answer, and only while the turn runs.
test("a running turn whose model said nothing says so, after every ask", () => {
  expect(chatWaitsOn({ ...chat, silent: true })).toBe("model");
  expect(chatWaitsOn({ ...chat, silent: true, individualPermission: toolAsk })).toBe("permission");
  expect(chatWaitsOn({ ...chat, silent: true, isWorking: false })).toBeUndefined();
  expect(chatWaitsOn(chat)).toBeUndefined();
  const html = within("model", <Thinking />);
  expect(html).toContain(translate("turn.waiting.model"));
  expect(html).not.toContain(`>${translate("thinking")}<`);
});

// Leo 2026-10-21, Full access: the agent asked a multiple-choice question (AskUserQuestion) and the
// running turn read "Waiting for you: allow this?". acpmux sends a question as a permission request
// (direct.ts `permissionFromMessage` maps it onto the pending ask's `question`), so the pending ask
// is the chat's one permission card; a question on it is a question, never a permission.
test("a pending ask that carries a question waits on an answer, not an allow", () => {
  const request = (toolCall: object) => ({
    toolCall: { toolCallId: "t1", ...toolCall },
    options: [
      { optionId: "allow_once", name: "Answer", kind: "allow_once" },
      { optionId: "reject_once", name: "Reject", kind: "reject_once" },
    ],
  });
  const claude = questionFromPermission({
    permissionId: "p1",
    session: "s1",
    request: request({
      rawInput: { questions: [{ question: "Which database?", options: [{ label: "Postgres" }, { label: "SQLite" }] }] },
      _meta: { claude: { tool: "AskUserQuestion" } },
    }),
  });
  const normalized = questionFromPermission({
    permissionId: "p2",
    session: "s1",
    request: request({
      _meta: {
        acpmux: {
          question: {
            harness: "claude",
            items: [{ id: "q0", prompt: "Which database?", options: [{ id: "a", label: "Postgres" }] }],
          },
        },
      },
    }),
  });
  for (const question of [claude, normalized]) {
    expect(question).toBeDefined();
    const waiting = chatWaitsOn({ ...chat, individualPermission: { question } });
    expect(waiting).toBe("question");
    const row = { id: "working-1", version: 1, at: 0, kind: "working", doing: "AskUserQuestion" } as AcpmuxRow;
    const html = within(waiting, <WorkingFor row={row} now={() => 5_000} />);
    expect(html).toContain(translate("turn.waiting.question"));
    expect(html).not.toContain(translate("turn.waiting.permission"));
    // The trust question still holds it out of the stack.
    expect(chatWaitsOn({ ...chat, holdsAsks: true, individualPermission: { question } })).toBeUndefined();
  }
  // A plain tool permission still asks to allow.
  expect(chatWaitsOn({ ...chat, individualPermission: toolAsk })).toBe("permission");
  // A pending permission group beside the question is the first ask the stack shows.
  const group = { individualPermission: { question: claude }, permissionGroups: [{ state: "pending" as const }] };
  expect(chatWaitsOn({ ...chat, ...group })).toBe("permission");
});
