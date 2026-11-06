// The Bookmarks page's store over the mock provider: it reads the host state then the tree, re-lists
// on a newer revision of its profile only, drops stale search replies, makes one apply per action,
// keeps the editor open on a bad URL or a refusal, and reveals a node in its folder.
import { expect, test } from "bun:test";
import { MockBookmarksProvider, sampleBookmarks } from "../src/pages/bookmarks/mockProvider";
import { BookmarksStore } from "../src/pages/bookmarks/store";
import { BookmarkOps, HostOps, type Bookmark } from "../src/pages/bookmarks/types";
import type { PageClient } from "../src/pages/shared/pageClient";

const tick = () => new Promise<void>((done) => setTimeout(done, 0));

async function started(provider = new MockBookmarksProvider()) {
  let keys = 0;
  const store = new BookmarksStore(provider, { newKey: () => `k${++keys}`, newFolderTitle: "New Folder" });
  await store.start();
  return { store, provider };
}

const byTitle = (store: BookmarksStore, title: string): Bookmark =>
  [...store.getSnapshot().tree.nodes.values()].find((node) => node.title === title)!;
const titlesOf = (rows: readonly Bookmark[]) => rows.map((row) => row.title || row.url);
const applies = (provider: MockBookmarksProvider) => provider.calls.filter((call) => call.op === BookmarkOps.apply);

test("start reads the host state, then lists the profile's tree", async () => {
  const { store, provider } = await started();
  expect(provider.calls.slice(0, 2).map((call) => call.op)).toEqual([HostOps.state, BookmarkOps.list]);
  expect(provider.calls[1]?.params).toEqual({ browser_profile_id: "default" });
  const snap = store.getSnapshot();
  expect(snap.connection).toBe("connected");
  expect(snap.titles).toEqual({ bar: "Bookmarks Bar", other: "Other Bookmarks" });
  expect(titlesOf(snap.rows)).toEqual(["Work", "GitHub", "Reading", "https://news.ycombinator.com/"]);
});

test("a change of another profile or an old revision is not re-listed; a newer one is", async () => {
  const listeners: Array<(data: unknown) => void> = [];
  let lists = 0;
  const client: PageClient = {
    call: async <R>(op: string) => {
      if (op === HostOps.state) {
        return { browser_profile_id: "p1", bar_title: "Bar", other_title: "Other", can_set_folder_icons: false } as R;
      }
      lists += 1;
      return { bookmarks_revision: 5, bookmarks: [] } as R;
    },
    subscribe: async <E>(stream: string, onEvent: (data: E, seq: number) => void) => {
      if (stream === BookmarkOps.changed) listeners.push(onEvent as (data: unknown) => void);
      return () => undefined;
    },
    handle: () => () => undefined,
  };
  const store = new BookmarksStore(client);
  await store.start();
  expect(lists).toBe(1);
  for (const listener of listeners) {
    listener({ browser_profile_id: "p2", bookmarks_revision: 9 });
    listener({ browser_profile_id: "p1", bookmarks_revision: 5 });
  }
  await tick();
  expect(lists).toBe(1);
  for (const listener of listeners) listener({ browser_profile_id: "p1", bookmarks_revision: 6 });
  await tick();
  expect(lists).toBe(2);
});

test("every keystroke searches and a stale reply is dropped", async () => {
  const replies: Array<(rows: Bookmark[]) => void> = [];
  const provider = new MockBookmarksProvider();
  const call = provider.call.bind(provider);
  provider.call = async <R>(op: string, params: unknown): Promise<R> => {
    if (op !== BookmarkOps.search) return call<R>(op, params);
    return new Promise<R>((done) => replies.push((bookmarks) => done({ bookmarks } as R)));
  };
  const { store } = await started(provider);
  store.setText("r");
  store.setText("ru");
  expect(replies.length).toBe(2);
  const rust = byTitle(store, "Rust docs");
  replies[1]?.([rust]);
  await tick();
  replies[0]?.([byTitle(store, "Reading")]);
  await tick();
  expect(titlesOf(store.getSnapshot().rows)).toEqual(["Rust docs"]);
  store.setText("");
  expect(store.getSnapshot().results).toBeNull();
});

test("a rename plus a move is one apply of an update and a move, then a re-list", async () => {
  const { store, provider } = await started();
  const docs = byTitle(store, "Docs");
  store.startEdit(docs);
  store.setEditor({ title: "Reference", folder: "other" });
  expect(await store.commitEditor()).toBe(true);
  expect(applies(provider).map((call) => call.params)).toEqual([
    {
      ops: [
        { op: "update", bookmark: docs.id, title: "Reference" },
        { op: "move", bookmark: docs.id, parent: "other", index: 2 },
      ],
      idempotency_key: "k1",
    },
  ]);
  expect(provider.calls.at(-1)?.op).toBe(BookmarkOps.list);
  expect(store.getSnapshot().editor).toBeUndefined();
  expect(byTitle(store, "Reference").parent).toBe("other");
});

test("a bad URL keeps the editor open without an apply; a refusal shows inline", async () => {
  const { store, provider } = await started();
  store.startAddBookmark();
  store.setEditor({ title: "x", url: "not a url" });
  expect(await store.commitEditor()).toBe(false);
  expect(store.getSnapshot().editor?.error).toEqual({ kind: "invalidURL" });
  expect(applies(provider)).toEqual([]);

  const refusing = new MockBookmarksProvider(sampleBookmarks(), { refuse: { code: "limit", message: "Too many." } });
  const second = await started(refusing);
  second.store.startAddBookmark();
  second.store.setEditor({ title: "x", url: "example.com" });
  expect(await second.store.commitEditor()).toBe(false);
  expect(second.store.getSnapshot().editor?.error).toEqual({ kind: "refused", message: "Too many." });
});

test("deleting a folder with its child selected is one apply that deletes the folder once", async () => {
  const { store, provider } = await started();
  const work = byTitle(store, "Work");
  const linear = byTitle(store, "Linear");
  await store.deleteSelection([linear.id, work.id]);
  expect(applies(provider).map((call) => call.params.ops)).toEqual([[{ op: "delete", bookmark: work.id }]]);
  expect(store.getSnapshot().tree.nodes.has(linear.id)).toBe(false);
});

test("a drop on a folder row moves into it; a drop into itself makes no call", async () => {
  const { store, provider } = await started();
  const github = byTitle(store, "GitHub");
  const reading = byTitle(store, "Reading");
  await store.dropOnRow([github.id], reading);
  expect(applies(provider).map((call) => call.params.ops)).toEqual([
    [{ op: "move", bookmark: github.id, parent: reading.id, index: 1 }],
  ]);
  const work = byTitle(store, "Work");
  await store.dropInto([work.id], byTitle(store, "Docs").id);
  expect(applies(provider).length).toBe(1);
});

test("reveal clears the search, shows the node's folder and selects it", async () => {
  const { store } = await started();
  store.setText("rust");
  await tick();
  const rust = byTitle(store, "Rust docs");
  store.reveal(rust.id);
  const snap = store.getSnapshot();
  expect(snap.text).toBe("");
  expect(snap.folder).toBe(rust.parent);
  expect(snap.selection).toEqual([rust.id]);
  expect(snap.rows.some((row) => row.id === rust.id)).toBe(true);
});

test("adds go into the shown folder, or the bar while searching", async () => {
  const { store } = await started();
  const work = byTitle(store, "Work");
  store.showFolder(work.id);
  store.startAddFolder();
  expect(store.getSnapshot().editor).toMatchObject({ folder: work.id, title: "New Folder", isFolder: true });
  store.cancelEditor();
  store.setText("git");
  store.startAddBookmark();
  expect(store.getSnapshot().editor?.folder).toBe("bar");
});

test("a reveal asked before the tree arrives shows the node with the first listing", async () => {
  const provider = new MockBookmarksProvider();
  const rust = provider.listing.find((node) => node.title === "Rust docs")!;
  const revealed: string[] = [];
  const store = new BookmarksStore(provider, { onRevealed: (id) => revealed.push(id) });
  store.reveal(rust.id);
  await store.start();
  expect(store.getSnapshot()).toMatchObject({ folder: rust.parent, selection: [rust.id], focus: rust.id });
  expect(revealed).toEqual([rust.id]);
});

test("an icons change asks again only for the rows that had no icon", async () => {
  const { store, provider } = await started();
  const rows = store.getSnapshot().rows;
  await store.requestIcons(rows);
  await store.requestIcons(rows);
  expect(provider.calls.filter((call) => call.op === HostOps.icons).length).toBe(1);
  provider.emitHostChanged("icons");
  await store.requestIcons(rows);
  expect(provider.calls.filter((call) => call.op === HostOps.icons).length).toBe(2);
  // An icons change never re-reads the tree.
  expect(provider.calls.filter((call) => call.op === BookmarkOps.list).length).toBe(1);
});
