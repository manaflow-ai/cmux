// l10n-allow-file: test fixture subagent names and acpmux's prompt text, not shipped UI.
// acpmux's ask that the chat's agent resume a subagent that failed on a transient error (acpmux
// hub/subagent_retry.rs `retry_text`, provenance `subagent_retry`) waits in the composer's queue as
// a compact labelled row, the subagent's name after "Resume subagent", never the prompt's raw text
// with its agent id (Leo, 2026-10-30: "this looks weird and unrendered").
import { expect, test } from "bun:test";
import { mergeQueue } from "../direct";
import { translate } from "../i18n";
import { subagentRetryNotice } from "./retryState";

const named =
  'Your subagent "Cap huge-blue deputy context cost" (agent id af0cbece62b15d0e1) failed on a transient upstream ' +
  'error (API Error: 529 overloaded (retry later)). Resume it with SendMessage to "af0cbece62b15d0e1": it picks up ' +
  "from its transcript. Start a new subagent for its task only if that resume fails. If it is already running " +
  "again, or you already resumed or replaced it, do nothing.";

test("acpmux's resume prompt reads as its subagent's name, agent id and error", () => {
  expect(subagentRetryNotice(named)).toEqual({
    name: "Cap huge-blue deputy context cost",
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // acpmux leaves the name out when it has none.
  expect(subagentRetryNotice(named.replace('"Cap huge-blue deputy context cost" ', ""))).toEqual({
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // A queue listing's preview is its first 200 characters: the error may be cut.
  expect(subagentRetryNotice(`${named.slice(0, 120)}…`)).toEqual({
    name: "Cap huge-blue deputy context cost",
    agentId: "af0cbece62b15d0e1",
  });
});

test("the record's subagent_retry provenance names the agent when the words do not", () => {
  const msg = { _meta: { provenance: { kind: "subagent_retry", subagentId: "s/t2", agentId: "a8e1b6", attempt: 1 } } };
  expect(subagentRetryNotice("Resume the subagent please.", msg)).toEqual({ agentId: "a8e1b6" });
  expect(subagentRetryNotice(named, msg)?.name).toBe("Cap huge-blue deputy context cost");
});

test("the person's own prompts are no resume", () => {
  expect(subagentRetryNotice("Your subagent looks stuck, can you check it?")).toBeUndefined();
  expect(subagentRetryNotice(`please do this: ${named}`)).toBeUndefined();
});

test("a queue listing gives the entry its resume, and another agent's message never has one", () => {
  const [entry] = mergeQueue([], [{ promptId: "p-1", prompt: named.slice(0, 200) }]);
  expect(entry?.retry).toEqual({ name: "Cap huge-blue deputy context cost", agentId: "af0cbece62b15d0e1" });
  const [message] = mergeQueue([], [{ promptId: "p-2", prompt: named.slice(0, 200), fromAgent: "coordinator" }]);
  expect(message?.message?.name).toBe("coordinator");
  expect(message?.retry).toBeUndefined();
});

test("the label is in the catalog", () => {
  expect(translate("composer.queuedSubagentRetry")).toBe("Resume subagent");
});
