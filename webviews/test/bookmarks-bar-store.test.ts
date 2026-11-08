// The bookmarks bar's store: it reads the profile, then only the bar's row and Other Bookmarks'
// count (never the whole tree); re-reads on a newer change of its profile or a relay resync; a
// profile change clears the old row; a folder's menu reads its subtree on the click; a refused
// drop says why through the host.
import { expect, test } from "bun:test";
import { BarOps, BookmarksBarStore } from "../src/browser-chrome/bookmarks-bar/store";
import { BookmarkOps, HostOps, type Bookmark } from "../src/pages/bookmarks/types";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";

const tick = () => new Promise<void>((done) => setTimeout(done, 0));
const words = { empty: "(empty)", openAll: (count: number) => `Open All (${count})` };

const row = (id: string, parent: string, index: number, kind: Bookmark["kind"] = "url"): Bookmark => ({
  id,
  browser_profile_id: "default",
  parent,
  kind,
  index,
  title: id,
  url: kind === "url" ? `https://${id}.example/` : undefined,
  created_ms: 0,
});

function fakeClient(options: { refuse?: boolean } = {}) {
  const calls: Array<{ op: string; params: Record<string, unknown> }> = [];
  const streams = new Map<string, (data: unknown) => void>();
  let profile = "default";
  let revision = 1;
  const tree = [row("work", "bar", 0, "folder"), row("a", "work", 0), row("b", "bar", 1), row("o", "other", 0)];
  const client: PageClient = {
    call: async <R>(op: string, params: unknown) => {
      const p = (params ?? {}) as Record<string, unknown>;
      calls.push({ op, params: p });
      if (op === HostOps.state) {
        return {
          browser_profile_id: profile,
          bar_title: "Bar",
          other_title: "Other",
          can_set_folder_icons: false,
        } as R;
      }
      if (op === BarOps.children) {
        const depth = (p.depth as number | undefined) ?? 1;
        const under = (parent: string, level: number): Bookmark[] =>
          tree
            .filter((node) => node.parent === parent)
            .flatMap((node) => [node, ...(level < depth ? under(node.id, level + 1) : [])]);
        const all = under(p.parent as string, 1);
        const limit = (p.limit as number | undefined) ?? 1000;
        return {
          bookmarks_revision: revision,
          bookmarks: all.slice(0, limit),
          total: tree.filter((node) => node.parent === p.parent).length,
          truncated: all.length > limit,
        } as R;
      }
      if (op === BookmarkOps.apply && options.refuse) throw pageError("bookmarks.limit", "Too many bookmarks.");
      return {} as R;
    },
    subscribe: async <E>(stream: string, onEvent: (data: E, seq: number) => void) => {
      streams.set(stream, (data) => onEvent(data as E, 0));
      return () => streams.delete(stream);
    },
    handle: () => () => undefined,
  };
  return {
    client,
    calls,
    emit: (stream: string, data: unknown) => streams.get(stream)?.(data),
    setProfile: (next: string) => (profile = next),
    bump: () => (revision += 1),
  };
}

test("the bar reads its own row and Other Bookmarks' count, never the whole tree", async () => {
  const fake = fakeClient();
  const store = new BookmarksBarStore(fake.client, words);
  await store.start();
  const ops = fake.calls.map((call) => call.op);
  expect(ops).not.toContain(BookmarkOps.list);
  expect(fake.calls.filter((call) => call.op === BarOps.children).map((call) => call.params)).toEqual([
    { browser_profile_id: "default", parent: "bar" },
    { browser_profile_id: "default", parent: "other", limit: 0 },
  ]);
  const snap = store.getSnapshot();
  expect(snap.loaded).toBe(true);
  expect(snap.items.map((item) => item.id)).toEqual(["work", "b"]);
  expect(snap.hasOther).toBe(true);
});

test("a newer change of its profile or a resync re-reads; another profile's or an old one does not", async () => {
  const fake = fakeClient();
  const store = new BookmarksBarStore(fake.client, words);
  await store.start();
  const reads = () => fake.calls.filter((call) => call.op === BarOps.children).length;
  const before = reads();
  fake.emit(BookmarkOps.changed, { browser_profile_id: "p2", bookmarks_revision: 9 });
  fake.emit(BookmarkOps.changed, { browser_profile_id: "default", bookmarks_revision: 1 });
  await tick();
  expect(reads()).toBe(before);
  fake.bump();
  fake.emit(BookmarkOps.changed, { browser_profile_id: "default", bookmarks_revision: 2 });
  await tick();
  expect(reads()).toBe(before + 2);
  fake.emit(BookmarkOps.changed, { resync: true });
  await tick();
  expect(reads()).toBe(before + 4);
});

test("a tab of another profile clears the old row until its own read lands", async () => {
  const fake = fakeClient();
  const store = new BookmarksBarStore(fake.client, words);
  await store.start();
  fake.setProfile("p2");
  const seen: boolean[] = [];
  store.subscribe(() => seen.push(store.getSnapshot().loaded));
  fake.emit(HostOps.changed, { reason: "state" });
  await tick();
  await tick();
  expect(seen[0]).toBe(false);
  expect(store.getSnapshot().profile).toBe("p2");
  expect(store.getSnapshot().loaded).toBe(true);
});

test("a folder's menu reads its subtree on the click and sends nested rows", async () => {
  const fake = fakeClient();
  const store = new BookmarksBarStore(fake.client, words);
  await store.start();
  const work = store.getSnapshot().items[0]!;
  await store.openFolder(work, { x: 2, y: 2, width: 60, height: 24 }, "work");
  const subtree = fake.calls.find((call) => call.op === BarOps.children && call.params.parent === "work");
  expect(subtree?.params).toMatchObject({ depth: 64 });
  const menu = fake.calls.find((call) => call.op === BarOps.menu);
  expect(menu?.params).toMatchObject({ title: "work", anchor: { x: 2, y: 2, width: 60, height: 24 } });
  expect(menu?.params.rows).toEqual([
    { kind: "bookmark", id: "a", title: "a", url: "https://a.example/", favicon_key: null },
  ]);
});

test("a drop is one apply with a key; a refusal is said through the host and the row is read again", async () => {
  const fake = fakeClient({ refuse: true });
  const store = new BookmarksBarStore(fake.client, words, () => "k1");
  await store.start();
  const reads = fake.calls.filter((call) => call.op === BarOps.children).length;
  await store.drop("https://new.example/", "New", 1);
  const apply = fake.calls.find((call) => call.op === BookmarkOps.apply);
  expect(apply?.params).toMatchObject({ idempotency_key: "k1", ops: [{ op: "create", parent: "bar", index: 1 }] });
  await tick();
  expect(fake.calls.find((call) => call.op === BarOps.refused)?.params).toEqual({ message: "Too many bookmarks." });
  expect(fake.calls.filter((call) => call.op === BarOps.children).length).toBeGreaterThan(reads);
});
