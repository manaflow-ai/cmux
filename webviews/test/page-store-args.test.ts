// The exact op and arguments each History and Stashed Tabs menu action sends, against the names
// their owners read: `history.open` reads `id` and `newTab` (HistoryHandlers.swift), the daemon's
// `history.site.remove` reads `host` and narrows to one profile only when `profile` is sent (the
// native page removed the host from every profile), `history.clear` reads `range` and `kinds`,
// and the stash ops read `stash`, `members` and `new_workspace` (StashPageProvider.swift).
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { HistoryStore } from "../src/pages/history/store";
import { ACTION_RUN, CLIPBOARD_WRITE, HistoryOps, type HistoryEntry } from "../src/pages/history/types";
import { StashStore } from "../src/pages/stash/store";
import { StashOps, type StashGroup } from "../src/pages/stash/types";

class RecordingClient implements PageClient {
  readonly calls: Array<{ op: string; params: unknown }> = [];

  constructor(private readonly answers: Record<string, unknown> = {}) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    return (this.answers[op] ?? {}) as R;
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(): () => void {
    return () => {};
  }

  sent(op: string): unknown[] {
    return this.calls.filter((call) => call.op === op).map((call) => call.params);
  }
}

const page: HistoryEntry = {
  id: "page:default:42",
  kind: "page",
  at_ms: 1,
  title: "Example",
  available: true,
  url: "https://docs.example.com/a",
  profile: "work",
};

test("History: each menu action sends the arguments its owner reads", async () => {
  const client = new RecordingClient();
  const store = new HistoryStore(client, { newKey: () => "k" });

  await store.open(page);
  await store.open(page, true);
  expect(client.sent(ACTION_RUN)).toEqual([
    { action: "history.open", args: { id: "page:default:42", newTab: false } },
    { action: "history.open", args: { id: "page:default:42", newTab: true } },
  ]);

  await store.remove(page);
  expect(client.sent(HistoryOps.remove)).toEqual([{ ids: ["page:default:42"], idempotency_key: "k" }]);

  await store.removeSite(page);
  expect(client.sent(HistoryOps.removeSite)).toEqual([{ host: "docs.example.com", idempotency_key: "k" }]);

  await store.clear("today");
  expect(client.sent(HistoryOps.clear)).toEqual([{ range: "today", idempotency_key: "k" }]);

  await store.copy("https://docs.example.com/a");
  expect(client.sent(CLIPBOARD_WRITE)).toEqual([{ text: "https://docs.example.com/a" }]);
});

test("Stashed Tabs: restore and delete send stash, members and new_workspace", async () => {
  const client = new RecordingClient({ [StashOps.delete]: { deleted: false }, [StashOps.list]: [] });
  const store = new StashStore(client);
  const group = {
    id: "s1",
    created_at_ms: 1,
    members: [{ id: "m1", kind: "tab", url: "https://a.example/", tabs: [] }],
  } as unknown as StashGroup;
  const member = group.members[0];

  await store.restore(group);
  await store.restore(group, [member]);
  await store.restore(group, undefined, true);
  expect(client.sent(StashOps.restore)).toEqual([
    { stash: "s1", new_workspace: false },
    { stash: "s1", members: ["m1"], new_workspace: false },
    { stash: "s1", new_workspace: true },
  ]);

  await store.delete(group);
  await store.delete(group, member);
  expect(client.sent(StashOps.delete)).toEqual([{ stash: "s1" }, { stash: "s1", members: ["m1"] }]);
});
