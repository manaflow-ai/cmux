import { expect, test } from "bun:test";
import { createEntryStore, entryPath, type EntrySource } from "../src/gallery/entryStore";

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

test("an entry file under src/gallery keeps its path (Vite keys it ./ from the registry)", () => {
  expect(entryPath("../pages/apps/apps.gallery.ts")).toBe("src/pages/apps/apps.gallery.ts");
  expect(entryPath("./fixtures/VisualMediaBoard.gallery.tsx")).toBe(
    "src/gallery/fixtures/VisualMediaBoard.gallery.tsx",
  );
});
