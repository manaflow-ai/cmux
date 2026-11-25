// The `subagent-report` seed's capped card opens whole in the showcase: Show more reads the
// subagent's own records from the mock daemon (App.tsx `readSubagentReply`), and those hold its
// whole reply while its card keeps acpmux's capped `lastMessage`.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

test("the capped subagent's own log in the mock daemon reads back its whole report", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { WORKED_SESSION } = await import("./mockFixture");
  const { CAPPED_ID, PREVIEW, REPORT, subagentReportLog, subagentReportRows } = await import("./subagentReportFixture");
  const { foldOwnLog } = await import("./subagents/subagentOwnLog");
  const { lastReply } = await import("./subagents/wholeReport");
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    await client.select(WORKED_SESSION);
    // Seeded twice, as repeated `seed_rows` calls do: the second replaces the first.
    MockAcpmuxSocket.live!.seedSubagentLog(WORKED_SESSION, CAPPED_ID, subagentReportLog());
    MockAcpmuxSocket.live!.seedSubagentLog(WORKED_SESSION, CAPPED_ID, subagentReportLog());
    const records = await client.readSubagentLog(CAPPED_ID);
    // Only that subagent's records, as acpmux's `EventFilter::of_subagent` pages them.
    expect(records).toHaveLength(3);
    const own = foldOwnLog(CAPPED_ID, records, { session: WORKED_SESSION, harness: "claude" });
    expect(lastReply(own.views[CAPPED_ID])).toBe(REPORT);
    // The card's row keeps only the capped preview.
    const group = subagentReportRows(0).at(-1) as unknown as {
      subagents: { id: string; result?: string; lastMessage?: string }[];
    };
    const capped = group.subagents.find((agent) => agent.id === CAPPED_ID)!;
    expect(capped.result).toBeUndefined();
    expect(capped.lastMessage).toBe(PREVIEW);
  } finally {
    client.close();
  }
});
