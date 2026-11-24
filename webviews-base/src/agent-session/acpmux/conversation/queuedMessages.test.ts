// The queue's split (queuedMessages.ts): the person's own prompts stay the composer's queue rows;
// another agent's messages become transcript rows, their received cards, in the queue's order.
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

test("each agent message is a received-card row, in the queue's order, with its promptId", () => {
  const queue: AcpmuxSnapshot["queue"] = [
    agent("a1", "Rebase first"),
    { id: "p1", prompt: "mine" },
    agent("a2", "CI is green", { next: true }),
  ];
  const rows = queuedMessageRows(queue);
  expect(rows.map((row) => row.id)).toEqual([queuedMessageRowId("a1"), queuedMessageRowId("a2")]);
  expect(rows.every((row) => row.kind === QUEUED_MESSAGE && row.untyped === true)).toBe(true);
  expect(rows[0]!.incoming).toEqual({ kind: "message", message: queue[0]!.message! });
  // The first waiting message carries the marker for a Stop hold note; all are in the pending group.
  expect(rows[0]!.queuedMessage).toEqual({ promptId: "a1", lead: true });
  // Sent now already (acpmux marked it next): its card offers no second Steer.
  expect(rows[1]!.queuedMessage).toEqual({ promptId: "a2", next: true });
  expect(queuedMessageRows([{ id: "p1", prompt: "mine" }])).toEqual([]);
});

test("the same entries keep their rows; a changed entry draws again", () => {
  const first = agent("a1", "Rebase first");
  const second = agent("a2", "CI is green");
  const rows = queuedMessageRows([first, second]);
  // The same queue gives the same array back, so the transcript keeps its rows' identity.
  expect(queuedMessageRows([first, second], rows)).toBe(rows);
  // acpmux replaced an entry (an edit): its row is new, with a newer version; the other is kept.
  const edited = agent("a2", "CI is green; merging");
  const next = queuedMessageRows([first, edited], rows);
  expect(next).not.toBe(rows);
  expect(next[0]).toBe(rows[0]);
  expect(next[1]!.id).toBe(rows[1]!.id);
  expect(next[1]!.version).toBeGreaterThan(rows[1]!.version);
  expect(next[1]!.text).toBe("CI is green; merging");
});
