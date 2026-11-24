// l10n-allow-file: test fixture subagent names and acpmux's prompt text, not shipped UI.
// acpmux's ask that the chat's agent resume a subagent that failed on a transient error (acpmux
// hub/subagent_retry.rs `retry_text`, provenance `subagent_retry`) waits in the composer's queue as
// a compact labelled row, the subagent's name after "Resume subagent", never the prompt's raw text
// with its agent id (Leo, 2026-10-30: "this looks weird and unrendered"). Only its record's
// provenance makes it one: the person's own prompt in the same words stays theirs.
import { expect, test } from "bun:test";
import { mergeQueue } from "../direct";
import { translate } from "../i18n";
import { retryErrorDetail, retryErrorKind, retryErrorSummary, subagentRetryNotice } from "./retryState";

/// The `queued` record's provenance acpmux puts on the resume (subagent_retry.rs).
const marked = {
  _meta: { provenance: { kind: "subagent_retry", subagentId: "s/t2", agentId: "af0cbece62b15d0e1", attempt: 1 } },
};

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
  expect(
    subagentRetryNotice(named, { _meta: { provenance: { kind: "person_message", from: "u-2" } } }),
  ).toBeUndefined();
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
  const [edited] = mergeQueue(
    [had],
    [{ promptId: "p-5", client: "acpmux", prompt: `${named.slice(0, 199)}…` }],
    undefined,
    new Set(["p-5"]),
  );
  expect(edited?.retry).toBeUndefined();
  // Another agent's message, or a teammate's prompt, never keeps one.
  expect(listed(`${named.slice(0, 199)}…`, { fromAgent: "coordinator" })?.retry).toBeUndefined();
  expect(listed(`${named.slice(0, 199)}…`, { author: { id: "u-2", name: "Austin" } })?.retry).toBeUndefined();
});

test("a listing's subagentRetry names the resume with no record read (a chat reopened past the page)", () => {
  // review-28042-ux-4: the resume's `queued` record can fall outside the attach's latest events.
  const subagentRetry = { agentId: "af0cbece62b15d0e1", name: 'Fix "Resume" button', error: "529" };
  const [entry] = mergeQueue(
    [],
    [
      {
        promptId: "p-8",
        client: "acpmux",
        prompt: `${named.slice(0, 199)}…`,
        fromAgent: null,
        author: null,
        subagentRetry,
      },
    ],
  );
  expect(entry?.retry).toEqual(subagentRetry);
  // The same listing with subagentRetry null (acpmux saw it edited, or it is the person's) is none,
  // even over a resume the pane had read.
  const had = { id: "p-8", prompt: named, retry: subagentRetry };
  const [edited] = mergeQueue(
    [had],
    [
      {
        promptId: "p-8",
        client: "acpmux",
        prompt: `${named.slice(0, 199)}…`,
        fromAgent: null,
        author: null,
        subagentRetry: null,
      },
    ],
  );
  expect(edited?.retry).toBeUndefined();
});

test("an old-style resume keeps the name and error read from its words when the listing has only the id", () => {
  // Queued before acpmux named them in its provenance: the record's words gave them, the listing
  // gives only the agent id.
  const recovered = subagentRetryNotice(named, marked)!;
  expect(recovered.name).toBe("Cap the deputy context cost");
  const had = { id: "p-9", prompt: named, retry: recovered };
  const list = (subagentRetry: unknown) =>
    mergeQueue(
      [had],
      [
        {
          promptId: "p-9",
          client: "acpmux",
          prompt: `${named.slice(0, 199)}…`,
          fromAgent: null,
          author: null,
          subagentRetry,
        },
      ],
    )[0];
  expect(list({ agentId: "af0cbece62b15d0e1", name: null, error: null })?.retry).toEqual(recovered);
  // The listing's own name and error win.
  expect(list({ agentId: "af0cbece62b15d0e1", name: "Renamed", error: "503" })?.retry).toEqual({
    agentId: "af0cbece62b15d0e1",
    name: "Renamed",
    error: "503",
  });
  // Another agent id is another resume: nothing carries over.
  expect(list({ agentId: "other-id", name: null, error: null })?.retry).toEqual({ agentId: "other-id" });
  // Null still removes it.
  expect(list(null)?.retry).toBeUndefined();
});

test("the record's provenance names the subagent and the error over the words", () => {
  const withNames = {
    _meta: { provenance: { ...marked._meta.provenance, name: "Push relay", error: "API Error: 503" } },
  };
  expect(subagentRetryNotice("anything at all", withNames)).toEqual({
    name: "Push relay",
    agentId: "af0cbece62b15d0e1",
    error: "API Error: 503",
  });
});

test("the label is in the catalog", () => {
  expect(translate("composer.queuedSubagentRetry")).toBe("Resume subagent");
});

// cmux#51938 (Austin, 2026-11-23: "its really bad, why do we have this?"): the queued resume dumped
// a 529's whole text inline, its gateway host and request id included. The row names the cause in a
// word; opened, the provider's sentences without the host or request id.
const overloaded =
  "Agent terminated early due to an API error: API Error: Repeated 529 Overloaded errors. The API is at " +
  "capacity — this is usually temporary. Try again in a moment. If it persists, check your inference " +
  "gateway (sr2-gateway.tail137216.ts.net:4016). (error type server_error, HTTP 529, request id req_016L";

test("a resume's error reads as its cause in a word", () => {
  const t = (key: string) => translate(key as Parameters<typeof translate>[0]);
  expect(retryErrorKind(overloaded)).toBe("overloaded");
  expect(retryErrorSummary(t, overloaded)).toBe("Overloaded");
  expect(retryErrorSummary(t, "API Error: 529 overloaded (retry later)")).toBe("Overloaded");
  expect(retryErrorSummary(t, "429 Too Many Requests")).toBe("Rate limited");
  expect(retryErrorSummary(t, "stream disconnected before completion: error sending request")).toBe(
    "Connection failed",
  );
  expect(retryErrorSummary(t, "connect ECONNREFUSED 127.0.0.1:4016")).toBe("Connection failed");
  expect(retryErrorSummary(t, "agent process closed")).toBe("Agent exited");
  expect(retryErrorSummary(t, "API Error: 502 Bad Gateway")).toBe("Server error");
  expect(retryErrorSummary(t, "something odd")).toBe("Temporary error");
  expect(retryErrorSummary(t, undefined)).toBeUndefined();
  expect(retryErrorSummary(t, "  ")).toBeUndefined();
});

test("an opened resume's error keeps the provider's sentences, never a host, URL or request id", () => {
  const detail = retryErrorDetail(overloaded)!;
  expect(detail).toBe(
    "Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary. Try again in a moment.",
  );
  for (const plumbing of ["ts.net", "4016", "req_", "request id", "error type", "Agent terminated", "API Error:"])
    expect(detail).not.toContain(plumbing);
  expect(retryErrorDetail("API Error: 529 overloaded (retry later)")).toBe("529 overloaded (retry later)");
  expect(retryErrorDetail("Upstream failed at https://gw.example.com:8443/v1/messages.")).toBeUndefined();
  expect(retryErrorDetail("Overloaded (request id req_abc). Retry soon.")).toBe("Overloaded. Retry soon.");
  expect(retryErrorDetail(undefined)).toBeUndefined();
});

test("every cause has its words in the catalog", () => {
  for (const kind of ["overloaded", "rateLimited", "network", "agentExited", "server", "other"] as const)
    expect(translate(`composer.queuedRetryWhy.${kind}`)).not.toBe(`composer.queuedRetryWhy.${kind}`);
});
