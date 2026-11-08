// Another agent's message waiting in the queue is that message (direct.ts `queuedMessage`), which
// its row draws as its received line: as its provenance gives it, as the transcript reads it once
// it runs, else as acpmux's `fromAgent` names its sender. The person's own prompt is none, and
// acpmux's queue list (which names no sender) keeps the one the record gave.
import { expect, test } from "bun:test";
import { mergeQueue, queuedMessage } from "./direct";

test("a queued agent's message reads as its provenance gives it", () => {
  const message = (provenance: Record<string, unknown>) => ({
    text: "Rebase first",
    client: "acpmux",
    promptId: "p1",
    _meta: { provenance },
  });
  expect(queuedMessage(message({ kind: "agent_message", from: "acp:s-deputy", fromName: "coord-deputy" }))).toEqual({
    name: "coord-deputy",
    sessionId: "s-deputy",
    text: "Rebase first",
    raw: "Rebase first",
  });
  expect(
    queuedMessage(
      message({ kind: "session_message", from: "acp:s-lane", fromName: "claude-sr2/lane", fromShortName: "lane" }),
    ),
  ).toEqual({ name: "lane", sessionId: "s-lane", text: "Rebase first", raw: "Rebase first" });
  // `acpmux send` from a shell names its sender in brackets.
  expect(queuedMessage({ text: "[coord-deputy] Merged #1", client: "acpmux-cli#42" })).toEqual({
    name: "coord-deputy",
    text: "Merged #1",
    raw: "[coord-deputy] Merged #1",
  });
});

test("acpmux's fromAgent names the sender, and a lead that only repeats it goes", () => {
  expect(queuedMessage({ text: "Rebase first", client: "acpmux", fromAgent: " claude-sr2 " })).toEqual({
    name: "claude-sr2",
    text: "Rebase first",
    raw: "Rebase first",
  });
  expect(
    queuedMessage({ text: "From claude-sr2: Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text,
  ).toBe("Rebase first");
  expect(queuedMessage({ text: "[claude-sr2] Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text).toBe(
    "Rebase first",
  );
  // Another name in brackets is the message's own text.
  expect(queuedMessage({ text: "[WIP] Rebase first", client: "acpmux", fromAgent: "claude-sr2" })?.text).toBe(
    "[WIP] Rebase first",
  );
});

test("the person's queued prompt is no agent's message", () => {
  expect(queuedMessage({ text: "Also update the comment", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedMessage({ text: "[WIP] fix the parser", client: "cmux-pane#1" })).toBeUndefined();
  expect(queuedMessage({ text: "Rebase first", client: "acpmux", fromAgent: "  " })).toBeUndefined();
  expect(queuedMessage(undefined)).toBeUndefined();
});

test("acpmux's queue list keeps the message its record gave", () => {
  const message = { name: "coord-deputy", text: "Rebase first", raw: "Rebase first" };
  const current = [
    { id: "p1", prompt: "Rebase first", message },
    { id: "p2", prompt: "Also update the comment" },
  ];
  const listed = mergeQueue(current, [
    { promptId: "p2", prompt: "Also update the comment" },
    { promptId: "p1", prompt: "Rebase first" },
  ]);
  expect(listed).toEqual([
    { id: "p2", prompt: "Also update the comment" },
    { id: "p1", prompt: "Rebase first", message },
  ]);
});

test("a queue row the pane never read the record of is an agent's message when the list names it", () => {
  const listed = mergeQueue(
    [],
    [
      { promptId: "p1", prompt: "Rebase first", fromAgent: "lane-a" },
      { promptId: "p2", prompt: "Also update the comment", fromAgent: null },
    ],
  );
  expect(listed).toEqual([
    { id: "p1", prompt: "Rebase first", message: { name: "lane-a", text: "Rebase first", raw: "Rebase first" } },
    { id: "p2", prompt: "Also update the comment" },
  ]);
});

test("a queue listing with agent_message provenance keeps its sender without fromAgent", () => {
  const listed = mergeQueue(
    [],
    [
      {
        promptId: "p-provenance",
        prompt: "Rebase first",
        client: "acpmux",
        _meta: { provenance: { kind: "agent_message", from: "acp:s-deputy", fromName: "coord-deputy" } },
      },
    ],
  );
  expect(listed[0]?.message).toEqual({
    name: "coord-deputy",
    sessionId: "s-deputy",
    text: "Rebase first",
    raw: "Rebase first",
  });
});

test("a queue row the list says is the person's drops the agent's name its record gave", () => {
  const message = { name: "lane-a", text: "Rebase first", raw: "Rebase first" };
  // Edited past the preview's cut: the head the list shows is the same, the sender is not.
  const current = [{ id: "p1", prompt: "Rebase first, then push", message }];
  const listed = mergeQueue(current, [{ promptId: "p1", prompt: "Rebase first", fromAgent: null }]);
  expect(listed).toEqual([{ id: "p1", prompt: "Rebase first, then push" }]);
  // An older acpmux names no sender: the record's stays.
  expect(mergeQueue(current, [{ promptId: "p1", prompt: "Rebase first" }])).toEqual(current);
});

// An agent's message the person edited, and a prompt acpmux could not attribute, are no agent's to
// act on (`fromAgent` null) but still name a sender: acpmux lists their provenance, so a pane that
// never read their record (an attach, a reconnect) draws their card and its mark, never the
// person's own row.
test("a listed edited or unverified prompt keeps its sender card without its record", () => {
  const edited = mergeQueue(
    [],
    [
      {
        promptId: "p1",
        prompt: "my words",
        fromAgent: null,
        provenance: { kind: "agent_message", from: "acp:s-a", fromName: "lane-a", editedBy: { actor: "owner" } },
      },
    ],
  );
  expect(edited[0]?.message).toMatchObject({ name: "lane-a", edited: true, text: "my words" });
  const unverified = mergeQueue(
    [],
    [
      {
        promptId: "p2",
        prompt: "deploy now",
        fromAgent: null,
        provenance: { kind: "unverified", to: "s2", transport: "unix", verified: false },
      },
    ],
  );
  expect(unverified[0]?.message).toMatchObject({ unverified: true });
});

// A shared chat: a teammate's prompt is not another agent's message, and acpmux's queue list keeps
// the author its `queued` record named.
test("a teammate's queued prompt keeps its author through acpmux's list", () => {
  const ana = { id: "tailnet:ana@example.com", name: "Ana" };
  const person = {
    text: "Rebase first",
    promptId: "p1",
    _meta: { provenance: { kind: "person_message", from: ana.id, fromName: ana.name } },
  };
  expect(queuedMessage(person)).toBeUndefined();
  const listed = mergeQueue(
    [{ id: "p1", prompt: "Rebase first", author: ana }],
    [{ promptId: "p1", prompt: "Rebase first", fromAgent: null }],
  );
  expect(listed[0]?.author).toEqual(ana);
});

// Leo, 2026-10-29, on a sub-session's note to its parent drawn as a plain box of raw text: "why is
// this styled like this?". `acpmux send --no-wait` delivers through the daemon's outbox, whose
// client is `acpmux-outbox#…`: its "From <name>:" names the sender as a shell's does.
test("a sub-session's note through the outbox names its sender, not the person", () => {
  const text = "From claude-sr2/ui-think-tank: merged https://github.com/teamleaderleo/leo-workspace/pull/1234";
  expect(queuedMessage({ text, client: "acpmux-outbox#7@cosmic", promptId: "p9" })).toEqual({
    name: "claude-sr2/ui-think-tank",
    text: "merged https://github.com/teamleaderleo/leo-workspace/pull/1234",
    raw: text,
  });
  // The person's own words stay theirs: "From now on" names no agent, and the person sends through
  // the outbox too, so a bracket lead there is theirs, never a sender named "P1".
  expect(queuedMessage({ text: "From now on: rebase first", client: "acpmux-outbox#7" })).toBeUndefined();
  expect(queuedMessage({ text: "[P1] Fix the crash", client: "acpmux-outbox#7" })).toBeUndefined();
});

// Review of #37653 (F1): a queued record's text is the whole message. One that only starts like the
// broker's label, from a client that names its sender in `fromAgent` alone (no relay record), keeps
// its words; only a list's one-line preview is read as possibly cut inside a label.
test("a whole queued message that only starts like a relay label keeps its words", () => {
  const text = "[message 1234abcd from a lane: the parser is fixed";
  expect(queuedMessage({ text, client: "acpmux", fromAgent: "lane-a" })?.text).toBe(text);
  // A whole label around it, closed by its own nonce, is still left out.
  const relayed = `[message 1234abcd from vm-1/lane-a (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 1234abcd]"]\nthe parser is fixed\n[end of message 1234abcd]`;
  expect(queuedMessage({ text: relayed, client: "acpmux", fromAgent: "vm-1/lane-a" })?.text).toBe(
    "the parser is fixed",
  );
});

test("a queue list's preview cut inside a relay label reads as nothing of the label", () => {
  const listed = mergeQueue(
    [],
    [
      {
        promptId: "p1",
        preview: "[message 1234abcd from vm-1/lane-a (an agent, not Leo), relayed by the lane-gh br…",
        fromAgent: "vm-1/lane-a",
      },
    ],
  );
  expect(listed[0]?.message?.text).toBe("");
});

// cmux#38642 review: a queued `agent_message` record names its sender (`fromName`) but carries no
// proof of it (no `fromRelay`, no `fromSessionId`), so a first line that only looks like the
// broker's head is the sender's own text: anyone can type one. Only a sender acpmux proved loses a
// head with no closing line; any other keeps it, and only a whole closed label goes.
test("a queued agent message with no proven sender keeps a relay-looking first line", () => {
  const head =
    '[message 1234abcd from vm-1/lane-a (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 1234abcd]"]';
  const text = `${head}\nthe parser is fixed`;
  const record = (provenance: Record<string, unknown>) => ({
    text,
    client: "acpmux",
    promptId: "p1",
    _meta: { provenance },
  });
  const named = { kind: "agent_message", from: "fromAgent", fromName: "lane-a", to: "s-1" };
  expect(queuedMessage(record(named))?.text).toBe(text);
  // acpmux's `fromAgent` alone names the sender, no proof either.
  expect(queuedMessage({ text, client: "acpmux", fromAgent: "lane-a", promptId: "p2" })?.text).toBe(text);
  // A relay's record proves the sender: the head the broker wrote is left out.
  const proven = { ...named, fromRelay: { by: "lane-gh", machine: "vm-1", session: "lane-a" } };
  expect(queuedMessage(record(proven))?.text).toBe("the parser is fixed");
  // A whole closed label is the broker's, read so for any agent's record.
  const closed = `${text}\n[end of message 1234abcd]`;
  expect(queuedMessage({ ...record(named), text: closed })?.text).toBe("the parser is fixed");
});
