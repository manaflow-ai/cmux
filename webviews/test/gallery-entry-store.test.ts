import { expect, test } from "bun:test";
import { createEntryStore, type EntrySource } from "../src/gallery/entryStore";

const entry = (id: string) => ({
  id,
  title: id,
  area: "Test",
  host: "component" as const,
  covers: [`test/${id}`],
  variants: { initial: { props: {} } },
});

test("find resolves a requested entry before a slow sibling", async () => {
  let resolveTarget!: (value: ReturnType<typeof entry>) => void;
  let resolveSibling!: (value: ReturnType<typeof entry>) => void;
  const sources: EntrySource[] = [
    { path: "src/target.gallery.tsx", load: () => new Promise((resolve) => (resolveTarget = resolve)) },
    { path: "src/slow.gallery.tsx", load: () => new Promise((resolve) => (resolveSibling = resolve)) },
  ];
  const store = createEntryStore(sources);
  const target = store.find("test.target");

  await Promise.resolve();
  resolveTarget(entry("test.target"));
  await expect(target).resolves.toMatchObject({ entry: { id: "test.target" } });

  // Do not leave the store's intentionally slow sibling pending after the assertion.
  resolveSibling(entry("test.slow"));
});

test("bounded loading keeps only the configured number of entry modules active", async () => {
  let active = 0;
  let peak = 0;
  const sources: EntrySource[] = Array.from({ length: 5 }, (_, index) => ({
    path: `src/${index}.gallery.tsx`,
    load: async () => {
      active++;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active--;
      return entry(`test.${index}`);
    },
  }));
  const store = createEntryStore(sources, { concurrency: 2 });
  await store.settled();
  expect(peak).toBe(2);
  expect(store.getSnapshot().every((state) => state.status === "ready")).toBe(true);
});
