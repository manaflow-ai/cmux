// l10n-allow-file: test fixture subagent names and acpmux's prompt text, not shipped UI.
// acpmux's ask that the chat's agent resume a subagent that failed on a transient error (acpmux
// hub/subagent_retry.rs `retry_text`, provenance `subagent_retry`) waits in the composer's queue as
// a compact labelled row, the subagent's name after "Resume subagent", never the prompt's raw text
// with its agent id (Leo, 2026-10-30: "this looks weird and unrendered").
import { expect, test } from "bun:test";
import { mergeQueue } from "../direct";
import { translate } from "../i18n";
import { subagentRetryNotice as notice } from "./retryState";

/// acpmux sends the resume as its own client.
const subagentRetryNotice = (text: string, msg: Parameters<typeof notice>[1] = { client: "acpmux" }) => notice(text, msg);

const named =
  'Your subagent "Cap the deputy context cost" (agent id af0cbece62b15d0e1) failed on a transient upstream ' +
  'error (API Error: 529 overloaded (retry later)). Resume it with SendMessage to "af0cbece62b15d0e1": it picks up ' +
  "from its transcript. Start a new subagent for its task only if that resume fails. If it is already running " +
  "again, or you already resumed or replaced it, do nothing.";

test("acpmux's resume prompt reads as its subagent's name, agent id and error", () => {
  expect(subagentRetryNotice(named)).toEqual({
    name: "Cap the deputy context cost",
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // acpmux leaves the name out when it has none.
  expect(subagentRetryNotice(named.replace('"Cap the deputy context cost" ', ""))).toEqual({
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // A queue listing's preview is its first 200 characters: the error may be cut.
  expect(subagentRetryNotice(`${named.slice(0, 120)}…`)).toEqual({
    name: "Cap the deputy context cost",
    agentId: "af0cbece62b15d0e1",
  });
});

test("a preview a long name cuts before the error, or in the agent id or the name, still names it", () => {
  const long = "x".repeat(140);
  const full = `Your subagent "${long}" (agent id abc123) failed on a transient upstream error (529). Resume it`;
  const preview = (n: number) => `${full.slice(0, n)}…`;
  // Cut in "failed on a transient upstream error".
  expect(subagentRetryNotice(preview(full.indexOf(" failed") + 9))).toEqual({ name: long, agentId: "abc123" });
  // Cut right after the agent id.
  expect(subagentRetryNotice(preview(full.indexOf(" failed")))).toEqual({ name: long, agentId: "abc123" });
  // Cut in the agent id: the name alone.
  expect(subagentRetryNotice(preview(full.indexOf("abc123") + 3))).toEqual({ name: long });
  // Cut right after the name, or inside " (agent id ": the name alone.
  const named180 = `Your subagent "${"x".repeat(180)}" (agent id abc123) failed on a transient upstream error (529).`;
  for (const n of [196, 198, 200, 205])
    expect(subagentRetryNotice(`${named180.slice(0, n)}…`)).toEqual({ name: "x".repeat(180) });
  // Cut in the name: as much of it as there is.
  expect(subagentRetryNotice(preview(60))).toEqual({ name: `${full.slice(15, 60)}…` });
  // Something else after the agent id is no resume.
  expect(subagentRetryNotice(`Your subagent "a" (agent id abc123) is fine.`)).toBeUndefined();
});

test("the record's subagent_retry provenance names the agent when the words do not", () => {
  const msg = { _meta: { provenance: { kind: "subagent_retry", subagentId: "s/t2", agentId: "a8e1b6", attempt: 1 } } };
  expect(notice("Resume the subagent please.", msg)).toEqual({ agentId: "a8e1b6" });
  expect(notice(named, msg)?.name).toBe("Cap the deputy context cost");
});

test("the person's own prompts are no resume, even in acpmux's exact words", () => {
  expect(subagentRetryNotice("Your subagent looks stuck, can you check it?")).toBeUndefined();
  expect(subagentRetryNotice(`please do this: ${named}`)).toBeUndefined();
  // Pasted by the person (any client but acpmux, with no subagent_retry provenance).
  expect(notice(named, { client: "cmux-next" })).toBeUndefined();
  expect(notice(named)).toBeUndefined();
  const [own] = mergeQueue([], [{ promptId: "p-3", client: "cmux-next", prompt: `${named.slice(0, 120)}…` }]);
  expect(own?.retry).toBeUndefined();
});

test("a queue listing gives the entry its resume, and another agent's message never has one", () => {
  const [entry] = mergeQueue([], [{ promptId: "p-1", client: "acpmux", prompt: `${named.slice(0, 120)}…` }]);
  expect(entry?.retry).toEqual({ name: "Cap the deputy context cost", agentId: "af0cbece62b15d0e1" });
  const [message] = mergeQueue(
    [],
    [{ promptId: "p-2", client: "acpmux", prompt: `${named.slice(0, 120)}…`, fromAgent: "coordinator" }],
  );
  expect(message?.message?.name).toBe("coordinator");
  expect(message?.retry).toBeUndefined();
});

test("the label is in the catalog", () => {
  expect(translate("composer.queuedSubagentRetry")).toBe("Resume subagent");
});

test("a teammate's prompt in acpmux's words, or an edit the pane missed, is no resume", () => {
  const listed = `${named.slice(0, 120)}…`;
  const [theirs] = mergeQueue([], [{ promptId: "p-4", client: "acpmux", prompt: listed, author: { id: "u-2", name: "Austin" } }]);
  expect(theirs?.retry).toBeUndefined();
  const [held] = mergeQueue([], [{ promptId: "p-5", client: "acpmux", prompt: listed }]);
  expect(held?.retry?.agentId).toBe("af0cbece62b15d0e1");
  // The person rewrote it while the pane was away: the listing's own words decide.
  const [edited] = mergeQueue([held!], [{ promptId: "p-5", client: "acpmux", prompt: "just check the logs" }]);
  expect(edited?.retry).toBeUndefined();
  // Cut to a shorter prompt it began with, whole (no "…"): the edit is the person's too.
  const [whole] = mergeQueue([], [{ promptId: "p-6", client: "acpmux", prompt: named }]);
  expect(whole?.retry?.agentId).toBe("af0cbece62b15d0e1");
  const [shorter] = mergeQueue([whole!], [{ promptId: "p-6", client: "acpmux", prompt: named.slice(0, 40) }]);
  expect(shorter?.retry).toBeUndefined();
  // The same prompt listed again keeps its resume.
  const [again] = mergeQueue([whole!], [{ promptId: "p-6", client: "acpmux", prompt: `${named.slice(0, 199)}…` }]);
  expect(again?.retry?.agentId).toBe("af0cbece62b15d0e1");
});
