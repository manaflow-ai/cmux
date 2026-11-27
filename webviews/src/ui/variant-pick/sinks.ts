import type { PickRecord, PickSink } from "./model";

export type PickRequest = (input: string, init: RequestInit) => Promise<Response>;

/** Same-origin hosted gallery endpoint. Identity/time are never sent as authority. */
export function beadsPickSink(beadId: string, request: PickRequest = fetch): PickSink {
  return {
    async record(pick) {
      const { who: _who, when: _when, ...choice } = pick;
      const response = await request("/api/pick", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({ beadId, ...choice }),
      });
      if (!response.ok) throw new Error("Pick comment was not confirmed");
      const receipt = (await response.json()) as PickRecord;
      if (
        typeof receipt.who !== "string" ||
        !receipt.who ||
        typeof receipt.when !== "string" ||
        !Number.isFinite(Date.parse(receipt.when)) ||
        receipt.variantId !== pick.variantId ||
        receipt.entryId !== pick.entryId ||
        receipt.threadId !== pick.threadId ||
        (receipt.recommendedId ?? null) !== (pick.recommendedId ?? null) ||
        receipt.note !== pick.note
      )
        throw new Error("Invalid pick receipt");
      return receipt;
    },
  };
}

/** Leo's lane replaces this. It intentionally does not claim that a feed post exists. */
export const noopFeedSink: PickSink = { record: async (pick) => pick };

export async function recordPick(pick: PickRecord, beads: PickSink, feed: PickSink): Promise<PickRecord> {
  const receipt = await beads.record(pick);
  return feed.record(receipt);
}
