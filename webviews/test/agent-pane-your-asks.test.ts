// l10n-allow-file: test fixtures (sample asks and repos), not shipped UI.
// Your asks (asks/asksModel.ts): the `_acpmux/asks` reply read defensively, and History's wiring
// (queue/historyPages.ts): the read goes to the pane's connection, a chat opens in this tab, a pull
// request in a browser tab, and an acpmux client without the method reads as an older daemon.
import { expect, test } from "bun:test";
import { askLedgerEnabled, askLine, prLabel, readAsks } from "../src/agent-session/acpmux/asks/asksModel";
import { historyPages } from "../src/agent-session/acpmux/queue/historyPages";
import { isOlderDaemon } from "../src/agent-session/acpmux/queue/queueModel";

test("an asks reply is read defensively", () => {
  const reply = readAsks({
    asks: [
      {
        id: "ask-0123456789",
        ts: 5,
        text: "\n  first line  \nsecond",
        harness: "claude",
        sessionId: "chat",
        sessionTitle: "The chat",
        host: "mac",
        status: "merged",
        prs: [{ url: "https://github.com/a/b/pull/3", repo: "a/b", number: 3, state: "merged" }, { nope: 1 }],
      },
      { id: "ask-no-session", ts: 1 },
      { id: "ask-aaaaaaaaaa", ts: 2, sessionId: "c", status: "weird", prs: [{ url: "https://x/y", state: "?" }] },
    ],
    next: 2,
  });
  expect(reply.next).toBe(2);
  expect(reply.asks.map((a) => a.id)).toEqual(["ask-0123456789", "ask-aaaaaaaaaa"]);
  const [first, second] = reply.asks;
  expect(askLine(first!)).toBe("first line");
  expect(first!.prs).toEqual([{ url: "https://github.com/a/b/pull/3", repo: "a/b", number: 3, state: "merged" }]);
  expect(prLabel(first!.prs[0]!)).toBe("#3");
  expect(second!.status).toBe("open");
  expect(second!.prs[0]!.state).toBe("open");
  expect(prLabel(second!.prs[0]!)).toBe("y");
  expect(readAsks(undefined)).toEqual({ asks: [] });
});

test("History's Your asks reads through the pane and opens chats and pull requests", async () => {
  const calls: unknown[] = [];
  const opened: string[] = [];
  const client = {
    ledger: async () => ({}),
    teamAudit: async () => ({}),
    teamDirectory: async () => ({}),
    reviewQueue: async () => ({}),
    reviewVerdict: async () => ({}),
    audit: async () => ({}),
    askLedger: async (params: Record<string, unknown>) => {
      calls.push(params);
      return { asks: [] };
    },
  };
  const native: unknown[] = [];
  const pages = historyPages({
    client: () => client,
    callNative: async <T>(method: string, params?: Record<string, unknown>) => {
      native.push([method, params]);
      return undefined as T;
    },
    selectSession: (id) => opened.push(id),
    asks: [],
  });
  expect(await pages.yourAsks.load({ limit: 5 })).toEqual({ asks: [] });
  expect(calls).toEqual([{ limit: 5 }]);
  pages.yourAsks.openSession("chat-1");
  expect(opened).toEqual(["chat-1"]);
  pages.yourAsks.openUrl("https://github.com/a/b/pull/3");
  expect(native).toEqual([["tab.open", { kind: "browser", text: "https://github.com/a/b/pull/3" }]]);

  const { askLedger: _askLedger, ...withoutAsks } = client;
  const older = historyPages({
    client: () => withoutAsks,
    callNative: async <T>() => undefined as T,
    selectSession: () => undefined,
    asks: [],
  });
  const error = await older.yourAsks.load({}).catch((e: unknown) => e);
  expect(isOlderDaemon(error)).toBe(true);
});

test("the Labs tab requires an explicit daemon opt-in", () => {
  for (const reply of [undefined, null, {}, { asks: [] }, { enabled: false }, { enabled: "true" }]) {
    expect(askLedgerEnabled(reply)).toBe(false);
  }
  expect(askLedgerEnabled({ enabled: true, asks: [] })).toBe(true);
});
