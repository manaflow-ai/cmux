// l10n-allow-file: test fixture subagent names, ids and messages, not shipped UI.
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { subagentRelayPrompt, subagentRelaySteers, subagentTarget, workflowAgentTarget } from "./subagentMessage";

const claude = { id: "s1/toolu_01", name: "Reviewer", agentId: "a39e817af38ddf5e7" };

test("a Claude subagent is reached by the agentId its Agent call answered with, named by its task", () => {
  expect(subagentTarget(claude, "claude")).toEqual({ name: "Reviewer", id: "a39e817af38ddf5e7", claude: true });
  expect(subagentTarget({ ...claude, task: "Review the PR" }, "claude").name).toBe("Review the PR");
  // Before its Agent call answers (a foreground one still running), it is named only.
  expect(subagentTarget({ ...claude, agentId: undefined }, "claude")).toEqual({ name: "Reviewer", claude: true });
});

test("a profile of a harness (claude-sr2, codex_work) reaches its subagents as that harness does", () => {
  expect(subagentTarget(claude, "claude-sr2")).toEqual({ name: "Reviewer", id: "a39e817af38ddf5e7", claude: true });
  expect(subagentTarget({ id: "019a-thread", name: "Read a" }, "codex_work").id).toBe("019a-thread");
  // A name that only starts like one is another harness.
  expect(subagentTarget(claude, "claudette").claude).toBe(false);
});

test("a Codex subagent is reached by its thread id, which acpmux records as its subagent id", () => {
  expect(subagentTarget({ id: "019a-thread", name: "Read a" }, "codex")).toEqual({
    name: "Read a",
    id: "019a-thread",
    claude: false,
  });
  // Another harness's subagent id is acpmux's own: it is named only.
  expect(subagentTarget({ id: "child-1", name: "Helper" }, "opencode")).toEqual({ name: "Helper", claude: false });
});

test("the relay asks the chat's agent to pass the message on as typed, naming the subagent", () => {
  const message = "Also check {name} and the retry tests";
  expect(subagentRelayPrompt(subagentTarget(claude, "claude"), message, translate)).toBe(
    'Use SendMessage to send your subagent "Reviewer" (agentId a39e817af38ddf5e7) the message below, word for word. If it has finished, SendMessage resumes it.\n\nAlso check {name} and the retry tests',
  );
  expect(subagentRelayPrompt({ name: "Reviewer", claude: true }, "Go on", translate)).toBe(
    'Use SendMessage to send your subagent "Reviewer" the message below, word for word. If it has finished, SendMessage resumes it.\n\nGo on',
  );
  expect(subagentRelayPrompt({ name: "Read a", id: "019a", claude: false }, "Go on", translate)).toBe(
    'Send your subagent "Read a" (id 019a) the message below, word for word. If it can no longer take messages, say so.\n\nGo on',
  );
  expect(subagentRelayPrompt({ name: "Helper", claude: false }, "Go on", translate)).toBe(
    'Send your subagent "Helper" the message below, word for word. If it can no longer take messages, say so.\n\nGo on',
  );
});

test("a workflow's agent is named by its label, with Claude's agentId for it", () => {
  expect(workflowAgentTarget({ label: "Lint", agentId: "w1" }, "Subagent")).toEqual({
    name: "Lint",
    id: "w1",
    claude: false,
  });
  expect(workflowAgentTarget({}, "Subagent")).toEqual({ name: "Subagent", claude: false });
});

test("a message to a subagent steers only into a running turn of an agent that steers", () => {
  // The subagent still works under the chat's turn: its agent reads the message at its next step.
  expect(subagentRelaySteers({ isWorking: true, summary: { steering: true } })).toBe(true);
  // The subagent is done and the chat idle: a steer would be refused, so it is a prompt of its own.
  expect(subagentRelaySteers({ isWorking: false, summary: { steering: true } })).toBe(false);
  // An agent that cannot steer waits for the turn instead.
  expect(subagentRelaySteers({ isWorking: true, summary: { steering: false } })).toBe(false);
  expect(subagentRelaySteers({ isWorking: true })).toBe(false);
});
