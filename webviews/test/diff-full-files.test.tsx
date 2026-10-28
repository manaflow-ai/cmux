// l10n-allow-file: test fixture file names and file text, not shipped UI.
// Load full files ("..." menu, Codex parity): the viewer asks the host for each shown file's two
// sides (`fileContents`) and parses the file's own patch again with them, so its unchanged lines
// expand. The hunks stay git's, the cache key changes (a highlight of the partial parse has fewer
// lines), and the option off parses the patch alone again.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { processFile } = await import("@pierre/diffs");
const full = await import("../src/diff-viewer/fullFiles");
const { PATCH_TEXT_KEY } = await import("../src/kept-patch-text");
const root = createRoot(dom.window.document.getElementById("root")!);
afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const rows = (from: number, to: number, change?: Record<number, string>) =>
  Array.from({ length: to - from + 1 }, (_, at) => `${change?.[from + at] ?? `row ${from + at}`}\n`).join("");
const OLD = rows(1, 60);
const NEW = rows(1, 60, { 5: "row five", 50: "row fifty" });
/** `git diff` of long.txt: rows 5 and 50 changed, two hunks with 38 and 7 unmodified lines around. */
const PATCH = `diff --git a/long.txt b/long.txt
index 1111111..2222222 100644
--- a/long.txt
+++ b/long.txt
@@ -2,7 +2,7 @@
 row 2
 row 3
 row 4
-row 5
+row five
 row 6
 row 7
 row 8
@@ -47,7 +47,7 @@
 row 47
 row 48
 row 49
-row 50
+row fifty
 row 51
 row 52
 row 53
`;
const streamed = () => {
  const fileDiff = processFile(PATCH, { cacheKey: "cmux-diff-file-0-abc", isGitDiff: true })! as any;
  fileDiff[PATCH_TEXT_KEY] = PATCH;
  fileDiff.cmuxPatchFingerprint = "fingerprint";
  return fileDiff;
};
const sides = { old: { contents: OLD, encoding: "text" as const }, new: { contents: NEW, encoding: "text" as const } };

test("Load full files applies to a git source whose host reads files, not to a chat's turn", () => {
  const payload = { sessionCapabilities: ["session.ignoreWhitespace", "session.fileContents"] };
  expect(full.fullFilesAvailable(payload, { kind: "unstaged", repoRoot: "/r" })).toBe(true);
  expect(full.fullFilesAvailable(payload, { kind: "branch", repoRoot: "/r", baseRef: "HEAD" })).toBe(true);
  expect(full.fullFilesAvailable(payload, { kind: "patch", path: "/turn.patch" })).toBe(false);
  expect(full.fullFilesAvailable({ sessionCapabilities: [] }, { kind: "unstaged", repoRoot: "/r" })).toBe(false);
  expect(full.fullFilesAvailable({}, { kind: "unstaged", repoRoot: "/r" })).toBe(false);
});

test("only an edited or renamed file with hunks and its patch kept asks for its sides", () => {
  expect(full.fullFileRequest(streamed())).toEqual({ path: "long.txt" });
  const renamed = { ...streamed(), type: "rename-changed", prevName: "short.txt" };
  expect(full.fullFileRequest(renamed)).toEqual({ path: "long.txt", previousPath: "short.txt" });
  for (const fileDiff of [
    { ...streamed(), type: "new" },
    { ...streamed(), type: "deleted" },
    { ...streamed(), hunks: [] },
    { ...streamed(), [PATCH_TEXT_KEY]: undefined },
    full.withFullFiles(streamed(), sides, processFile),
  ])
    expect(full.fullFileRequest(fileDiff)).toBeNull();
});

test("the sides make the diff whole: git's hunks, a new cache key, the stream's marks kept", () => {
  const partial = streamed();
  expect(partial.isPartial).toBe(true);
  const whole = full.withFullFiles(partial, sides, processFile);
  expect(whole.isPartial).toBe(false);
  expect(whole.hunks).toHaveLength(2);
  expect(whole.hunks.map((hunk: any) => [hunk.additionStart, hunk.additionCount])).toEqual(
    partial.hunks.map((hunk: any) => [hunk.additionStart, hunk.additionCount]),
  );
  // Every line of the new file is there, so Pierre can show the 38 lines between the hunks.
  expect(whole.additionLines).toHaveLength(60);
  expect(whole.cacheKey).not.toBe(partial.cacheKey);
  expect(whole.cmuxPatchFingerprint).toBe("fingerprint");
  expect(whole[PATCH_TEXT_KEY]).toBe(PATCH);

  // Off again: the patch alone, with the first key back.
  const back = full.withoutFullFiles(whole, processFile);
  expect(back.isPartial).toBe(true);
  expect(back.cacheKey).toBe(partial.cacheKey);
  expect(back.additionLines).toHaveLength(partial.additionLines.length);
  expect(full.withoutFullFiles(partial, processFile)).toBeNull();
});

test("an answer without both text sides changes nothing", () => {
  const partial = streamed();
  expect(full.withFullFiles(partial, { tooLarge: true }, processFile)).toBeNull();
  expect(full.withFullFiles(partial, { new: sides.new }, processFile)).toBeNull();
  expect(
    full.withFullFiles(partial, { old: sides.old, new: { contents: "AAAA", encoding: "base64" } }, processFile),
  ).toBeNull();
});

test("sides that do not match the patch change nothing: a file changed since, or hunks hidden", () => {
  // Committed after the diff loaded: the old side already has the new row.
  const later = { ...sides, old: { contents: rows(1, 60, { 5: "row five" }), encoding: "text" as const } };
  expect(full.withFullFiles(streamed(), later, processFile)).toBeNull();
  // Hide imports took the first hunk out: its change would show as unchanged lines.
  const second = PATCH.slice(PATCH.indexOf("@@ -47"));
  const header = PATCH.slice(0, PATCH.indexOf("@@ -2"));
  const filtered = processFile(header + second, { cacheKey: "cmux-diff-file-0-def", isGitDiff: true })! as any;
  filtered[PATCH_TEXT_KEY] = header + second;
  expect(full.withFullFiles(filtered, sides, processFile)).toBeNull();
  // A last line with no newline still matches.
  const tailPatch = `diff --git a/t.txt b/t.txt
index 1111111..2222222 100644
--- a/t.txt
+++ b/t.txt
@@ -9,2 +9,2 @@
 row 9
-row 10
\\ No newline at end of file
+row ten
\\ No newline at end of file
`;
  const tail = processFile(tailPatch, { cacheKey: "cmux-diff-file-0-t", isGitDiff: true })! as any;
  tail[PATCH_TEXT_KEY] = tailPatch;
  const tailSides = {
    old: { contents: rows(1, 10).slice(0, -1), encoding: "text" as const },
    new: { contents: rows(1, 10, { 10: "row ten" }).slice(0, -1), encoding: "text" as const },
  };
  expect(full.withFullFiles(tail, tailSides, processFile)?.isPartial).toBe(false);
});

/** Renders the hook; resolves its reads by hand and records what it dispatches. */
async function harness(items: any[]) {
  const reads: { request: unknown; resolve: (value: any) => void }[] = [];
  const dispatched: any[] = [];
  const read = (request: unknown) => new Promise<any>((resolve) => reads.push({ request, resolve }));
  function Viewer(props: { items: any[]; enabled: boolean; sessionKey: string }) {
    full.useFullFiles({
      items: props.items,
      enabled: props.enabled,
      sessionKey: props.sessionKey,
      read,
      process: processFile,
      dispatch: (action: any) => dispatched.push(action),
    });
    return null;
  }
  const render = (enabled: boolean, sessionKey = "s1", next = items) =>
    act(async () => root.render(<Viewer items={next} enabled={enabled} sessionKey={sessionKey} />));
  return { reads, dispatched, render };
}

test("on, each shown file is read once and swapped for its whole parse; off parses it back", async () => {
  const item = { id: "long", fileDiff: streamed() };
  const collapsed = { id: "folded", collapsed: true, fileDiff: streamed() };
  const { reads, dispatched, render } = await harness([item, collapsed]);
  await render(false);
  expect(reads).toHaveLength(0);

  await render(true);
  // A collapsed file waits until it shows.
  expect(reads.map((entry) => entry.request)).toEqual([{ path: "long.txt" }]);
  await act(async () => reads[0]!.resolve(sides));
  expect(dispatched).toHaveLength(1);
  expect(dispatched[0]).toMatchObject({ type: "hydrate-item", itemId: "long", expectedFileDiff: item.fileDiff });
  expect(dispatched[0].fileDiff.isPartial).toBe(false);

  // The same session does not ask again.
  await render(true);
  expect(reads).toHaveLength(1);

  // Off: the whole parse goes back to the patch alone.
  const swapped = { ...item, fileDiff: dispatched[0].fileDiff };
  await render(false, "s1", [swapped, collapsed]);
  expect(dispatched.at(-1)).toMatchObject({ type: "hydrate-item", itemId: "long", expectedFileDiff: swapped.fileDiff });
  expect(dispatched.at(-1).fileDiff.isPartial).toBe(true);
});

test("an answer that arrives after the option went off, or for another session, is dropped", async () => {
  const item = { id: "long", fileDiff: streamed() };
  const { reads, dispatched, render } = await harness([item]);
  await render(true, "s1");
  await render(true, "s2");
  await act(async () => reads[0]!.resolve(sides));
  expect(dispatched).toHaveLength(0);
  // The new session asked for itself; its answer applies.
  expect(reads).toHaveLength(2);
  await act(async () => reads[1]!.resolve(sides));
  expect(dispatched).toHaveLength(1);
});

test("a refresh while every read slot is busy still reads the new files when the old reads end", async () => {
  const first = ["a", "b", "c", "d"].map((id) => ({ id, fileDiff: streamed() }));
  const { reads, render } = await harness(first);
  await render(true, "s1");
  expect(reads).toHaveLength(4);
  // The diff refreshed with one more file while the four reads run.
  await render(true, "s1", [...first, { id: "e", fileDiff: streamed() }]);
  expect(reads).toHaveLength(4);
  await act(async () => reads[0]!.resolve(sides));
  expect(reads).toHaveLength(5);
});

test("loadFileContents asks for one file in the shown session, base64 for a binary one", async () => {
  const { loadFileContents } = await import("../src/diff-viewer/session");
  const sent: unknown[] = [];
  const transport = {
    request: async (command: unknown) => {
      sent.push(command);
      return { type: "fileContents", value: { new: { contents: "iVBORw0=", encoding: "base64" } } };
    },
  } as never;
  const session = { capabilityToken: "token", sessionId: "s1" };
  const image = await loadFileContents(transport, session, { path: "dot.png", encoding: "base64" });
  expect(image.new?.encoding).toBe("base64");
  await loadFileContents(transport, session, { path: "long.txt", previousPath: "short.txt" });
  expect(sent).toEqual([
    {
      method: "fileContents",
      params: { capabilityToken: "token", sessionId: "s1", path: "dot.png", encoding: "base64" },
    },
    {
      method: "fileContents",
      params: { capabilityToken: "token", sessionId: "s1", path: "long.txt", previousPath: "short.txt" },
    },
  ]);
  const other = { request: async () => ({ type: "sessionClosed" }) } as never;
  await expect(loadFileContents(other, session, { path: "long.txt" })).rejects.toThrow();
});
