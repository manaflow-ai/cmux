import { expect, test } from "bun:test";
import { createEntryStore, type EntrySource } from "../src/gallery/entryStore";
import { prioritizeEntrySources } from "../src/gallery/registryPriority";

const entry = (id: string) => ({
  id,
  title: id,
  area: "Test",
  host: "component" as const,
  covers: [`test/${id}`],
  variants: { initial: { props: {} } },
});

test("deep-linked gallery routes prioritize their real source path", () => {
  const sources: EntrySource[] = [
    { path: "src/pages/history/history.gallery.ts", load: async () => entry("test.history") },
    { path: "src/agent-session/acpmux/Composer.gallery.tsx", load: async () => entry("test.composer") },
  ];
  expect(prioritizeEntrySources(sources, "agent-pane.composer")[0]?.path).toContain("Composer.gallery");
  expect(prioritizeEntrySources(sources, "pages.history")[0]?.path).toContain("history.gallery");
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

test("find resolves a requested entry while other bounded loads are still running", async () => {
  let releaseTarget!: (value: ReturnType<typeof entry>) => void;
  let releaseSibling!: (value: ReturnType<typeof entry>) => void;
  const sources: EntrySource[] = [
    { path: "src/target.gallery.tsx", load: () => new Promise((resolve) => (releaseTarget = resolve)) },
    { path: "src/sibling.gallery.tsx", load: () => new Promise((resolve) => (releaseSibling = resolve)) },
  ];
  const store = createEntryStore(sources, { concurrency: 2 });
  const found = store.find("test.target");
  await Promise.resolve();
  releaseTarget(entry("test.target"));
  await expect(found).resolves.toMatchObject({ entry: { id: "test.target" } });
  releaseSibling(entry("test.sibling"));
});

test("deferred registry loading keeps a foreground entry ahead of the background queue", async () => {
  const sources: EntrySource[] = Array.from({ length: 3 }, (_, index) => ({
    path: `src/deferred-${index}.gallery.tsx`,
    load: async () => entry(`test.deferred-${index}`),
  }));
  const store = createEntryStore(sources, { initial: 1, deferRemainingMs: 10 });
  await expect(store.find("test.deferred-0")).resolves.toMatchObject({ entry: { id: "test.deferred-0" } });
  await expect(store.find("test.deferred-2")).resolves.toMatchObject({ entry: { id: "test.deferred-2" } });
  await expect(store.settled()).resolves.toHaveLength(3);
});
