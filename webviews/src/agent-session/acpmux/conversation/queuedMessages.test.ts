// The queue's split (queuedMessages.ts): the person's own prompts stay the composer's queue rows;
// another agent's messages draw no row; a guest's prompts become transcript rows, in the queue's order.
import { expect, test } from "bun:test";
import { QUEUED_MESSAGE, type AcpmuxSnapshot } from "../model";
import { ownQueue, queuedMessageRowId, queuedMessageRows } from "./queuedMessages";

const agent = (id: string, text: string, extra: Partial<AcpmuxSnapshot["queue"][number]> = {}) => ({
  id,
  prompt: text,
  message: { name: "coord-deputy", sessionId: "s-deputy", text, raw: text },
  ...extra,
});

test("the person's prompts are the composer's queue; agent messages are not", () => {
  const own = { id: "p1", prompt: "Then add a test" };
  const later = { id: "p2", prompt: "And update the README" };
  const queue = [agent("a1", "Rebase first"), own, agent("a2", "CI is green"), later];
  expect(ownQueue(queue)).toEqual([own, later]);
  // A queue of the person's prompts alone is given back as it is.
  const mine = [own, later];
  expect(ownQueue(mine)).toBe(mine);
  expect(ownQueue([agent("a1", "x")])).toEqual([]);
});

const guest = (id: string, text: string, extra: Partial<AcpmuxSnapshot["queue"][number]> = {}) => ({
  id,
  prompt: text,
  awaitingOwner: true,
  author: { id: "guest:sam", name: "Sam" },
  ...extra,
});

// Leo, 2026-11-12: "STOP f***ing SHOWING THESE f***ing MESSAGES".
test("an agent message draws no row; a guest's held prompt is a row, in the queue's order, with its promptId", () => {
  const queue: AcpmuxSnapshot["queue"] = [
    agent("a1", "Rebase first"),
    guest("g1", "Can you look at the login page?"),
    { id: "p1", prompt: "mine" },
    agent("a2", "CI is green", { next: true }),
    guest("g2", "And the footer", { next: true }),
  ];
  const rows = queuedMessageRows(queue);
  expect(rows.map((row) => row.id)).toEqual([queuedMessageRowId("g1"), queuedMessageRowId("g2")]);
  expect(rows.every((row) => row.kind === QUEUED_MESSAGE && row.untyped === true)).toBe(true);
  expect(rows[0]!.incoming).toEqual({
    kind: "message",
    message: {
      name: "Sam",
      text: "Can you look at the login page?",
      raw: "Can you look at the login page?",
      fromPerson: true,
    },
  });
  // The first drawn message carries the marker for a Stop hold note; all are in the pending group.
  expect(rows[0]!.queuedMessage).toMatchObject({ promptId: "g1", lead: true });
  // Sent now already (acpmux marked it next): its card offers no second Steer.
  expect(rows[1]!.queuedMessage).toMatchObject({ promptId: "g2", next: true });
  expect(rows[1]!.queuedMessage?.lead).toBeUndefined();
  expect(queuedMessageRows([agent("a1", "Rebase first"), agent("a2", "CI is green")])).toEqual([]);
  expect(queuedMessageRows([{ id: "p1", prompt: "mine" }])).toEqual([]);
});

test("the same entries keep their rows; a changed entry draws again", () => {
  const first = guest("g1", "Rebase first");
  const second = guest("g2", "CI is green");
  const rows = queuedMessageRows([first, agent("a1", "hidden"), second]);
  // The same queue gives the same array back, so the transcript keeps its rows' identity.
  expect(queuedMessageRows([first, agent("a1", "hidden"), second], rows)).toBe(rows);
  // acpmux replaced an entry (an edit): its row is new, with a newer version; the other is kept.
  const edited = guest("g2", "CI is green; merging");
  const next = queuedMessageRows([first, edited], rows);
  expect(next).not.toBe(rows);
  expect(next[0]).toBe(rows[0]);
  expect(next[1]!.id).toBe(rows[1]!.id);
  expect(next[1]!.version).toBeGreaterThan(rows[1]!.version);
  expect(next[1]!.text).toBe("CI is green; merging");
});
