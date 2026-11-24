import { expect, test } from "bun:test";
import { HubApprovals, hubRows } from "./hubApprovals";
import { MOCK_HUB_CARDS, MOCK_HUB_REFUND, MockHubProvider } from "./mockHub";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("nothing waits: no rows, and a page without the hub route reads none", async () => {
  expect(hubRows(null)).toEqual([]);
  expect(hubRows({ overview: { ok: false, approvalCards: MOCK_HUB_CARDS } })).toEqual([]);
  const hub = new HubApprovals(null);
  const stop = hub.subscribe(() => undefined);
  await settle();
  expect(hub.getSnapshot().rows).toEqual([]);
  stop();
});

test("an answer keeps its card with the outcome until the next refresh", async () => {
  const provider = new MockHubProvider({ cards: [MOCK_HUB_REFUND] });
  const hub = new HubApprovals(provider);
  const stop = hub.subscribe(() => undefined);
  await settle();
  expect(hub.getSnapshot().rows.map((r) => r.card.approvalId)).toEqual([MOCK_HUB_REFUND.approvalId]);
  await hub.answer(MOCK_HUB_REFUND.approvalId, "approve");
  expect(provider.calls.find((c) => c.op === "cmux.settings.hub.run")?.params).toEqual({
    action: "approve",
    id: MOCK_HUB_REFUND.approvalId,
  });
  const [row] = hub.getSnapshot().rows;
  expect(row?.answer?.call?.outcomeText).toBe("Approved. It ran (re_3PqK2x).");
  await provider.call("cmux.settings.hub.run", { action: "refresh" });
  await settle();
  expect(hub.getSnapshot().rows).toEqual([]);
  stop();
});

test("a refused answer stays on its waiting card", async () => {
  const provider = new MockHubProvider({ cards: [MOCK_HUB_REFUND], refuse: "no longer waiting" });
  const hub = new HubApprovals(provider);
  const stop = hub.subscribe(() => undefined);
  await settle();
  await hub.answer(MOCK_HUB_REFUND.approvalId, "deny");
  const rows = hub.getSnapshot().rows;
  expect(rows).toHaveLength(1);
  expect(rows[0]?.answer?.refused?.message).toBe("no longer waiting");
  expect(rows[0]?.sending).toBe(false);
  stop();
});
