import { expect, test } from "bun:test";
import { parsePatchFiles } from "@pierre/diffs";
import {
  availabilityFromCheck,
  contentKey,
  hunkRefs,
  MAX_IN_FLIGHT,
  type HunkRef,
  type SummaryFileDiff,
  SummaryStore,
  summaryText,
} from "./hunkSummaries";
import { plainEnglishMenuItem, toolbarPillButtons } from "../toolbar-model";

// A fixture diff: one file, two hunks (a retry loop and a removed import).
const PATCH = `diff --git a/src/upload.ts b/src/upload.ts
--- a/src/upload.ts
+++ b/src/upload.ts
@@ -1,4 +1,3 @@
-import { legacy } from "./legacy";
 import { send } from "./net";
 // Uploads a file.
 export const name = "upload";
@@ -10,5 +9,9 @@ export async function upload(file: File) {
   const body = await file.arrayBuffer();
-  await send(body);
+  for (let attempt = 0; attempt < 3; attempt++) {
+    if (await send(body)) return true;
+  }
+  return false;
 }
`;

function fixture(patch = PATCH): SummaryFileDiff {
  const parsed = parsePatchFiles(patch);
  return parsed[0]!.files[0] as unknown as SummaryFileDiff;
}

test("each hunk's patch is its unified text, with a key, a preview and counts", () => {
  const refs = hunkRefs("item-1", fixture());
  expect(refs.map((ref) => ref.id)).toEqual(["item-1#0", "item-1#1"]);
  expect(refs[0]!.path).toBe("src/upload.ts");
  expect(refs[0]!.patch).toBe(
    '@@ -1,4 +1,3 @@\n-import { legacy } from "./legacy";\n import { send } from "./net";\n // Uploads a file.\n export const name = "upload";',
  );
  expect(refs[0]!.preview).toBe('import { legacy } from "./legacy";');
  expect([refs[0]!.additions, refs[0]!.deletions]).toEqual([0, 1]);
  expect(refs[1]!.patch.split("\n")[0]).toBe("@@ -10,5 +9,9 @@ export async function upload(file: File) {");
  expect(refs[1]!.patch).toContain("\n-  await send(body);\n+  for (let attempt = 0; attempt < 3; attempt++) {");
  // An added line comes first in the preview.
  expect(refs[1]!.preview).toBe("for (let attempt = 0; attempt < 3; attempt++) {");
  expect([refs[1]!.additions, refs[1]!.deletions]).toEqual([4, 1]);
  expect(hunkRefs("x", null)).toEqual([]);
});

test("a hunk's key is its content: the same hunk anywhere, a changed one anew", () => {
  const [first, second] = hunkRefs("a", fixture());
  const again = hunkRefs("b", fixture());
  expect(again[0]!.key).toBe(first!.key);
  expect(second!.key).not.toBe(first!.key);
  const changed = hunkRefs("a", fixture(PATCH.replace("attempt < 3", "attempt < 5")));
  // Only the changed hunk has a new key.
  expect(changed[0]!.key).toBe(first!.key);
  expect(changed[1]!.key).not.toBe(second!.key);
  expect(contentKey("ab", "c")).not.toBe(contentKey("a", "bc"));
});

/** Asks that answer when the test says, and the hunks asked about. */
function controlledAsk() {
  const asked: string[] = [];
  const pending = new Map<string, { resolve: (text: string) => void; reject: (e: Error) => void }>();
  const ask = (path: string, patch: string) => {
    asked.push(patch);
    return new Promise<string>((resolve, reject) => pending.set(patch, { resolve, reject }));
  };
  return { ask, asked, pending };
}

function refs(count: number): HunkRef[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `f#${i}`,
    itemId: "f",
    index: i,
    path: "f.ts",
    patch: `@@ -${i} +${i} @@\n+line ${i}`,
    key: contentKey("f.ts", `@@ -${i} +${i} @@\n+line ${i}`),
    preview: `line ${i}`,
    additions: 1,
    deletions: 0,
  }));
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("only wanted hunks are asked for, at most MAX_IN_FLIGHT at once, in reading order", async () => {
  const { ask, asked, pending } = controlledAsk();
  const store = new SummaryStore(ask);
  const all = refs(10);
  // Nothing on screen: nothing asked.
  store.want([]);
  expect(asked).toEqual([]);
  store.want(all.slice(0, 5));
  expect(store.inFlight).toBe(MAX_IN_FLIGHT);
  expect(asked).toEqual([all[0]!.patch, all[1]!.patch]);
  pending.get(all[0]!.patch)!.resolve("Adds line 0.");
  await settle();
  expect(store.get(all[0]!.key)).toEqual({ kind: "ready", text: "Adds line 0." });
  // The next wanted hunk takes the free slot.
  expect(asked).toEqual([all[0]!.patch, all[1]!.patch, all[2]!.patch]);
});

test("a hunk scrolled away before its turn is dropped, never asked", async () => {
  const { ask, asked, pending } = controlledAsk();
  const store = new SummaryStore(ask);
  const all = refs(10);
  store.want(all.slice(0, 6));
  expect(asked.length).toBe(2);
  // The person scrolls on: hunks 2-5 leave before they were asked; 8 and 9 come on screen.
  store.want(all.slice(8, 10));
  pending.get(all[0]!.patch)!.resolve("A.");
  pending.get(all[1]!.patch)!.resolve("B.");
  await settle();
  expect(asked).toEqual([all[0]!.patch, all[1]!.patch, all[8]!.patch, all[9]!.patch]);
  for (const dropped of all.slice(2, 6)) expect(store.get(dropped.key)).toEqual({ kind: "loading" });
  // The asks that were running still land: their sentences are kept for when they return.
  expect(store.get(all[1]!.key)).toEqual({ kind: "ready", text: "B." });
});

test("a kept sentence is never asked again, and a failure shows as failed", async () => {
  const { ask, asked, pending } = controlledAsk();
  const store = new SummaryStore(ask);
  const [a, b] = refs(2);
  let heard = 0;
  const stop = store.subscribe(a!.key, () => heard++);
  store.want([a!, b!]);
  pending.get(a!.patch)!.resolve("Adds a.");
  pending.get(b!.patch)!.reject(new Error("signed out"));
  await settle();
  expect(heard).toBe(1);
  expect(store.get(b!.key)).toEqual({ kind: "failed" });
  // Scrolling back over both asks nothing.
  store.want([a!, b!]);
  expect(asked.length).toBe(2);
  stop();
});

test("a closed store drops late answers", async () => {
  const { ask, pending } = controlledAsk();
  const store = new SummaryStore(ask);
  const [a] = refs(1);
  store.want([a!]);
  store.close();
  pending.get(a!.patch)!.resolve("Late.");
  await settle();
  expect(store.get(a!.key)).toEqual({ kind: "loading" });
});

test("the page cache holds at most its cap", async () => {
  const store = new SummaryStore(async (_path, patch) => `S ${patch.length}.`, 4, 3);
  const all = refs(5);
  store.want(all);
  await settle();
  await settle();
  const kept = all.filter((ref) => store.get(ref.key).kind === "ready");
  expect(kept.length).toBe(3);
});

test("the check answer names the toggle's state and reason", () => {
  expect(availabilityFromCheck({ ready: true, harness: "claude" })).toEqual({ kind: "ready" });
  expect(availabilityFromCheck({ ready: false, reason: "complete.not_installed" })).toEqual({
    kind: "unavailable",
    reasonKey: "plainEnglishNotInstalled",
  });
  expect(availabilityFromCheck({ ready: false, reason: "cmux.diff.no_acpmux" })).toEqual({
    kind: "unavailable",
    reasonKey: "plainEnglishNoAgent",
  });
  expect(availabilityFromCheck(null)).toEqual({ kind: "unavailable", reasonKey: "plainEnglishUnavailable" });
  expect(summaryText({ text: "  Adds a retry. " })).toBe("Adds a retry.");
  expect(summaryText({ text: "" })).toBeNull();
});

test("the toggle is a pill button where it fits and a menu row everywhere, off with its reason", () => {
  const state = {
    options: { collapsed: false, layout: "auto" as const, wordWrap: false },
    filesVisible: false,
    optionsOpen: false,
    findOpen: false,
  };
  const ready = { kind: "ready" } as const;
  const ids = (menuOnly: boolean) =>
    toolbarPillButtons(state, { on: false, availability: ready, menuOnly }).map((button) => button.id);
  expect(ids(false)).toContain("plainEnglish");
  // A narrow viewer: the pill keeps its old width.
  expect(ids(true)).not.toContain("plainEnglish");
  expect(toolbarPillButtons(state).map((button) => button.id)).toEqual(ids(true));
  expect(plainEnglishMenuItem({ on: true, availability: ready, menuOnly: true })).toMatchObject({
    id: "plain-english",
    checked: true,
    available: true,
  });
  expect(
    plainEnglishMenuItem({ on: false, availability: { kind: "unavailable", reasonKey: "plainEnglishNoAgent" } }),
  ).toMatchObject({ available: false, unavailableKey: "plainEnglishNoAgent" });
});
