// l10n-allow-file: fixture file names, not shipped UI.
// The Files page's search (Lucas 2026-10-17): the field's text asks the host once per pause in typing
// (each search walks the folder), a newer query wins over an older reply, and an empty field shows
// the tree again. Refresh searches again at once.
import { expect, test } from "bun:test";
import { FilesStore } from "../src/pages/files/store";
import { MockFilesProvider } from "../src/pages/files/mockProvider";
import { FilesOps } from "../src/pages/files/types";
import type { PageClient } from "../src/pages/shared/pageClient";

function counted() {
  const provider = new MockFilesProvider();
  const searches: string[] = [];
  const client = {
    call: (op: string, params: unknown) => {
      if (op === FilesOps.search) searches.push(String((params as { query: string }).query));
      return provider.call(op, params);
    },
    subscribe: provider.subscribe.bind(provider),
    handle: provider.handle.bind(provider),
  } as unknown as PageClient;
  return { store: new FilesStore(client), searches };
}

test("typing searches once after the pause, and the newest query's matches show", async () => {
  const { store, searches } = counted();
  void store.search("t");
  void store.search("ts");
  await store.search("tsx");
  expect(searches).toEqual(["tsx"]);
  expect(store.getSnapshot().results).toEqual(["src/components/Button.tsx", "src/components/Tree.tsx"]);
  await store.search("");
  expect(store.getSnapshot().results).toBeUndefined();
  expect(store.getSnapshot().query).toBe("");
});

test("refresh searches again without waiting", async () => {
  const { store, searches } = counted();
  await store.search("main");
  await store.refresh();
  expect(searches).toEqual(["main", "main"]);
  expect(store.getSnapshot().results).toEqual(["src/main.ts"]);
});
