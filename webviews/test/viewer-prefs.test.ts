import { afterEach, expect, test } from "bun:test";
import { loadViewerPrefs, sanitizeViewerPrefs, saveViewerPrefs } from "../src/viewer-prefs";

const originalWindow = (globalThis as any).window;

afterEach(() => {
  if (originalWindow === undefined) {
    delete (globalThis as any).window;
  } else {
    (globalThis as any).window = originalWindow;
  }
});

function makeStorage(): Storage & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return {
    data,
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
    removeItem: (key: string) => void data.delete(key),
    clear: () => data.clear(),
    key: () => null,
    get length() {
      return data.size;
    },
  } as any;
}

test("sanitizeViewerPrefs keeps known keys and drops invalid values", () => {
  expect(
    sanitizeViewerPrefs({
      layout: "split",
      diffIndicators: "classic",
      wordWrap: true,
      lineNumbers: "yes",
      bogus: 1,
    }),
  ).toEqual({ layout: "split", diffIndicators: "classic", wordWrap: true });
  expect(sanitizeViewerPrefs(null)).toEqual({});
  expect(sanitizeViewerPrefs("split")).toEqual({});
  expect(sanitizeViewerPrefs({ layout: "diagonal" })).toEqual({});
});

test("loadViewerPrefs prefers the native bridge reply", async () => {
  (globalThis as any).window = {
    webkit: {
      messageHandlers: {
        cmuxDiffComments: {
          postMessage: async (message: any) => {
            expect(message.method).toBe("viewerPrefs.get");
            return { ok: true, value: { preferences: { layout: "unified", wordDiffs: true, junk: 1 } } };
          },
        },
      },
    },
    localStorage: makeStorage(),
  };
  expect(await loadViewerPrefs()).toEqual({ layout: "unified", wordDiffs: true });
});

test("loadViewerPrefs falls back to localStorage when the bridge is unavailable", async () => {
  const storage = makeStorage();
  storage.setItem("cmux.diffViewer.options", JSON.stringify({ layout: "split", wordWrap: true }));
  (globalThis as any).window = { localStorage: storage };
  expect(await loadViewerPrefs()).toEqual({ layout: "split", wordWrap: true });
});

test("saveViewerPrefs posts to the bridge and merges into localStorage", async () => {
  const storage = makeStorage();
  storage.setItem("cmux.diffViewer.options", JSON.stringify({ wordWrap: true }));
  let posted: any = null;
  (globalThis as any).window = {
    webkit: {
      messageHandlers: {
        cmuxDiffComments: {
          postMessage: async (message: any) => {
            posted = message;
            return { ok: true, value: {} };
          },
        },
      },
    },
    localStorage: storage,
  };
  saveViewerPrefs({ layout: "unified" });
  expect(posted).toEqual({ method: "viewerPrefs.set", params: { preferences: { layout: "unified" } } });
  expect(JSON.parse(storage.getItem("cmux.diffViewer.options")!)).toEqual({
    layout: "unified",
    wordWrap: true,
  });
});
