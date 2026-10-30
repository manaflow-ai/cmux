// l10n-allow-file: test fixture subagent names and acpmux's prompt text, not shipped UI.
// acpmux's ask that the chat's agent resume a subagent that failed on a transient error (acpmux
// hub/subagent_retry.rs `retry_text`, provenance `subagent_retry`) waits in the composer's queue as
// a compact labelled row, the subagent's name after "Resume subagent", never the prompt's raw text
// with its agent id (Leo, 2026-10-30: "this looks weird and unrendered"). Only its record's
// provenance makes it one: the person's own prompt in the same words stays theirs.
import { expect, test } from "bun:test";
import { mergeQueue } from "../direct";
import { translate } from "../i18n";
import { subagentRetryNotice } from "./retryState";

/// The `queued` record's provenance acpmux puts on the resume (subagent_retry.rs).
const marked = { _meta: { provenance: { kind: "subagent_retry", subagentId: "s/t2", agentId: "af0cbece62b15d0e1", attempt: 1 } } };

const named =
  'Your subagent "Cap the deputy context cost" (agent id af0cbece62b15d0e1) failed on a transient upstream ' +
  'error (API Error: 529 overloaded (retry later)). Resume it with SendMessage to "af0cbece62b15d0e1": it picks up ' +
  "from its transcript. Start a new subagent for its task only if that resume fails. If it is already running " +
  "again, or you already resumed or replaced it, do nothing.";

test("acpmux's resume reads as its subagent's name, agent id and error", () => {
  expect(subagentRetryNotice(named, marked)).toEqual({
    name: "Cap the deputy context cost",
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // acpmux leaves the name out when it has none.
  expect(subagentRetryNotice(named.replace('"Cap the deputy context cost" ', ""), marked)).toEqual({
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 529 overloaded (retry later)",
  });
  // Words it does not recognise still name the agent from the provenance.
  expect(subagentRetryNotice("Resume the subagent please.", marked)).toEqual({ agentId: "af0cbece62b15d0e1" });
});

test("a name with quotes in it is the whole name", () => {
  const name = 'Fix "Resume" button';
  const full = `Your subagent "${name}" (agent id abc123) failed on a transient upstream error (529). Resume it`;
  expect(subagentRetryNotice(full, marked)).toEqual({ name, agentId: "af0cbece62b15d0e1", error: "529" });
});

test("without acpmux's provenance nothing is a resume, its exact words and its client included", () => {
  // The person's own prompt, pasted or edited (acpmux drops the provenance on an edit and keeps the
  // client), and a queue listing, which names no provenance: fromAgent and author are null for both.
  expect(subagentRetryNotice(named)).toBeUndefined();
  expect(subagentRetryNotice(named, { _meta: { provenance: { kind: "person_message", from: "u-2" } } })).toBeUndefined();
  for (const entry of [
    { promptId: "p-1", client: "acpmux", prompt: `${named.slice(0, 199)}…`, fromAgent: null, author: null },
    { promptId: "p-2", client: "cmux-next", prompt: named },
  ])
    expect(mergeQueue([], [entry])[0]?.retry).toBeUndefined();
});

test("a listing keeps the resume its queued record gave while the text is the same, never after an edit", () => {
  const retry = subagentRetryNotice(named, marked)!;
  const had = { id: "p-5", prompt: named, retry };
  const listed = (prompt: string, extra: Record<string, unknown> = {}) =>
    mergeQueue([had], [{ promptId: "p-5", client: "acpmux", prompt, fromAgent: null, author: null, ...extra }])[0];
  expect(listed(`${named.slice(0, 199)}…`)?.retry).toEqual(retry);
  // An edit the pane missed: shorter, whole (no "…"), or other words.
  expect(listed(named.slice(0, 40))?.retry).toBeUndefined();
  expect(listed("just check the logs")?.retry).toBeUndefined();
  // An edit the pane saw (queue_updated), even past the preview's cut.
  const [edited] = mergeQueue([had], [{ promptId: "p-5", client: "acpmux", prompt: `${named.slice(0, 199)}…` }], undefined, new Set(["p-5"]));
  expect(edited?.retry).toBeUndefined();
  // Another agent's message, or a teammate's prompt, never keeps one.
  expect(listed(`${named.slice(0, 199)}…`, { fromAgent: "coordinator" })?.retry).toBeUndefined();
  expect(listed(`${named.slice(0, 199)}…`, { author: { id: "u-2", name: "Austin" } })?.retry).toBeUndefined();
});

test("the label is in the catalog", () => {
  expect(translate("composer.queuedSubagentRetry")).toBe("Resume subagent");
});
