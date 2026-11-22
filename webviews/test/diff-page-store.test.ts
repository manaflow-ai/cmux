import { createDiffWrites } from "../src/diff-writes";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { bootPageDiff } from "../src/diff/pageBoot";
import { installPageDiffStore, pageDiffPrefsClient, pageDiffViewedClient } from "../src/diff/pageStore";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { loadViewedFiles, persistViewedChange } from "../src/viewed-files";
import { loadViewerPrefs, readLocalViewerPrefs, saveViewerPrefs } from "../src/viewer-prefs";

// Coordinator decision PAGE-PREFS: on the page host, prefs and viewed marks go through the host's
// ops, never web storage (the page host pool clears it on reset).
const STORE_OPS = [
  "cmux.diff.prefs.get",
  "cmux.diff.prefs.set",
  "cmux.diff.viewed.list",
  "cmux.diff.viewed.set",
  "cmux.diff.viewed.clear",
];

function fakePage(answer: (op: string, params: any) => unknown = () => ({})) {
  const calls: { op: string; params: any }[] = [];
  const page: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push({ op, params });
      return (await answer(op, params)) as R;
    },
    async subscribe() {
      throw pageError("cmux.protocol.unknown_op", "stream");
    },
    handle: () => () => undefined,
  };
  return { page, calls };
}

/** A web storage that records every access. */
function recordingStorage() {
  const touched: string[] = [];
  return {
    touched,
    storage: {
      getItem: (key: string) => (touched.push(`get ${key}`), null),
      setItem: (key: string) => void touched.push(`set ${key}`),
      removeItem: (key: string) => void touched.push(`remove ${key}`),
    },
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const originalWindow = (globalThis as any).window;
let storage: ReturnType<typeof recordingStorage>;

beforeEach(() => {
  storage = recordingStorage();
  (globalThis as any).window = { localStorage: storage.storage };
});

afterEach(() => {
  installPageDiffStore(null, undefined);
  (globalThis as any).window = originalWindow;
});

describe("diff page stores", () => {
  test("prefs load and save through the host's ops, one set per key, with no web storage", async () => {
    const { page, calls } = fakePage((op) =>
      op === "cmux.diff.prefs.get"
        ? { prefs: { wordWrap: true, layout: "stacked", collapsedFiles: ["/r\u0000a"] } }
        : {},
    );
    installPageDiffStore(page, STORE_OPS);
    expect(await loadViewerPrefs()).toEqual({ wordWrap: true, collapsedFiles: ["/r\u0000a"] });
    saveViewerPrefs({ layout: "unified", wordWrap: false }, createDiffWrites());
    await flush();
    expect(calls.slice(1)).toEqual([
      { op: "cmux.diff.prefs.set", params: { key: "layout", value: "unified" } },
      { op: "cmux.diff.prefs.set", params: { key: "wordWrap", value: false } },
    ]);
    expect(readLocalViewerPrefs()).toEqual({});
    expect(storage.touched).toEqual([]);
  });

  test("viewed marks load and change through the host's ops", async () => {
    const scope = { repoRoot: "/repo", source: "branch:main" };
    const { page, calls } = fakePage((op) =>
      op === "cmux.diff.viewed.list" ? { files: [{ path: "a", fingerprint: "f" }, { path: 1 }] } : {},
    );
    installPageDiffStore(page, STORE_OPS);
    expect(await loadViewedFiles(scope)).toEqual([{ path: "a", fingerprint: "f" }]);
    persistViewedChange(scope, { kind: "set", entry: { path: "b", fingerprint: "g" } }, createDiffWrites());
    persistViewedChange(scope, { kind: "clear", path: "a" }, createDiffWrites());
    await flush();
    expect(calls).toEqual([
      { op: "cmux.diff.viewed.list", params: { scope } },
      { op: "cmux.diff.viewed.set", params: { scope, file: { path: "b", fingerprint: "g" } } },
      { op: "cmux.diff.viewed.clear", params: { scope, path: "a" } },
    ]);
    expect(storage.touched).toEqual([]);
  });

  test("a host that does not list the ops gets none of them", () => {
    const { page } = fakePage();
    installPageDiffStore(page, ["cmux.diff.prefs.get"]);
    expect(pageDiffPrefsClient()).toBeNull();
    expect(pageDiffViewedClient()).toBeNull();
  });

  test("the boot installs the stores the config lists", async () => {
    const { page } = fakePage((op) =>
      op === "cmux.diff.config"
        ? { payload: { title: "Diff" }, ops: STORE_OPS }
        : Promise.reject(pageError("cmux.protocol.unknown_op", op)),
    );
    await bootPageDiff(
      page,
      () => undefined,
      () => undefined,
    );
    expect(pageDiffPrefsClient()).toBe(page);
    expect(pageDiffViewedClient()).toBe(page);
  });
});
