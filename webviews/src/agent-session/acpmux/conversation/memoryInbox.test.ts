// l10n-allow-file: test fixtures.
// The memory inbox card's state (memoryInbox.ts), derived from acpmux's `memory_offer` record and the
// `memory_resolved` records and `_acpmux/memory_resolve` answers that settle its facts.
import { expect, test } from "bun:test";
import {
  actionableFacts,
  memoryCardState,
  memoryOfferFromRecord,
  memoryRequestFailed,
  memoryRequestStarted,
  settleMemoryOffer,
} from "./memoryInbox";

const FACTS = ["Use bun, never npm.", "Run webview tests from webviews/.", "Ask before pushing."];
const RECORD = { offerId: "o1", file: "CLAUDE.md", facts: FACTS, heading: "## Learned in chats", created: false };
const offer = () => memoryOfferFromRecord(RECORD)!;

test("an offer record draws every fact pending, under its heading", () => {
  const card = memoryCardState(offer());
  expect(card).toMatchObject({ file: "CLAUDE.md", heading: "## Learned in chats", created: false });
  expect(card.facts.map((fact) => fact.state)).toEqual(["pending", "pending", "pending"]);
  expect(card.pending).toBe(3);
  expect(card.settled).toBe(false);
  expect(card.error).toBeUndefined();
  expect(actionableFacts(card)).toEqual(FACTS);
});

test("a record the card cannot draw is skipped; a long or repeated list is cut to three facts", () => {
  expect(memoryOfferFromRecord(undefined)).toBeUndefined();
  expect(memoryOfferFromRecord({ ...RECORD, offerId: "" })).toBeUndefined();
  expect(memoryOfferFromRecord({ ...RECORD, file: " " })).toBeUndefined();
  expect(memoryOfferFromRecord({ ...RECORD, facts: [] })).toBeUndefined();
  expect(memoryOfferFromRecord({ ...RECORD, facts: [" ", 4] })).toBeUndefined();
  const many = memoryOfferFromRecord({ ...RECORD, facts: ["a", "a ", "b", "c", "d"], heading: "" })!;
  expect(many.facts).toEqual(["a", "b", "c"]);
  expect(many.heading).toBeNull();
});

test("a partial resolution settles only its facts; the heading goes once one is accepted", () => {
  const partial = settleMemoryOffer(offer(), { offerId: "o1", file: "CLAUDE.md", accepted: [FACTS[0]], dismissed: [] });
  const card = memoryCardState(partial);
  expect(card.facts.map((fact) => fact.state)).toEqual(["accepted", "pending", "pending"]);
  expect(card.pending).toBe(2);
  expect(card.accepted).toBe(1);
  expect(card.heading).toBeNull();
  expect(card.settled).toBe(false);
  expect(actionableFacts(card)).toEqual(FACTS.slice(1));
  // A dismissal alone keeps the heading: the file does not have it yet.
  const dismissedOnly = settleMemoryOffer(offer(), { offerId: "o1", accepted: [], dismissed: [FACTS[2]] });
  expect(memoryCardState(dismissedOnly).heading).toBe("## Learned in chats");
});

test("several resolutions settle an offer; each fact keeps the first outcome named for it", () => {
  let state = settleMemoryOffer(offer(), { offerId: "o1", accepted: [FACTS[0]], dismissed: [] });
  // The same fact again (the record after the request's own answer) changes nothing.
  const again = settleMemoryOffer(state, { offerId: "o1", accepted: [], dismissed: [FACTS[0]] });
  expect(again).toBe(state);
  // Another offer's resolution and a fact the offer does not have are ignored.
  expect(settleMemoryOffer(state, { offerId: "o2", accepted: [FACTS[1]], dismissed: [] })).toBe(state);
  expect(settleMemoryOffer(state, { offerId: "o1", accepted: ["Something else"], dismissed: [] })).toBe(state);
  state = settleMemoryOffer(state, { offerId: "o1", accepted: [FACTS[1]], dismissed: [FACTS[2]] });
  const card = memoryCardState(state);
  expect(card.facts.map((fact) => fact.state)).toEqual(["accepted", "accepted", "dismissed"]);
  expect(card).toMatchObject({ pending: 0, accepted: 2, settled: true });
});

test("every fact dismissed settles the card with nothing accepted", () => {
  const card = memoryCardState(settleMemoryOffer(offer(), { offerId: "o1", accepted: [], dismissed: FACTS }));
  expect(card).toMatchObject({ settled: true, accepted: 0, pending: 0 });
});

test("a request in flight holds its facts; a failed one gives them back with the daemon's message", () => {
  const waiting = memoryRequestStarted(offer(), [FACTS[0]]);
  let card = memoryCardState(waiting);
  expect(card.facts[0].state).toBe("busy");
  // Still waiting on the person's word, but not actionable twice.
  expect(card.pending).toBe(3);
  expect(actionableFacts(card)).toEqual(FACTS.slice(1));
  const failed = memoryRequestFailed(waiting, [FACTS[0]], "EACCES: permission denied, open 'CLAUDE.md'");
  card = memoryCardState(failed);
  expect(card.error).toBe("EACCES: permission denied, open 'CLAUDE.md'");
  expect(card.facts[0].state).toBe("pending");
  expect(actionableFacts(card)).toEqual(FACTS);
  // The next request clears the error, and its answer settles the facts it names.
  const retried = memoryRequestStarted(failed, [FACTS[0]]);
  expect(memoryCardState(retried).error).toBeUndefined();
  const settled = settleMemoryOffer(failed, { accepted: [FACTS[0]], dismissed: [] });
  expect(memoryCardState(settled).error).toBeUndefined();
  expect(memoryCardState(settled).facts[0].state).toBe("accepted");
});

test("a new file says so until its first fact is accepted", () => {
  const created = memoryOfferFromRecord({ ...RECORD, created: true })!;
  expect(memoryCardState(created).created).toBe(true);
  expect(memoryCardState(settleMemoryOffer(created, { accepted: [FACTS[0]], dismissed: [] })).created).toBe(false);
});
