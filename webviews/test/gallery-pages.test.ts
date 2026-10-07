// The fixtures cross the real page stores' input contracts, without a browser process.
import { expect, test } from "bun:test";
import { fixtureOps } from "../src/gallery/frame/pageReplies";
import type { BridgePageVariant } from "../src/gallery/format";
import type { PageClient } from "../src/pages/shared/pageClient";
import apps from "../src/pages/apps/apps.gallery";
import changelog from "../src/pages/changelog/changelog.gallery";
import cloud from "../src/pages/cloud/cloud.gallery";
import coderouter from "../src/pages/coderouter/coderouter.gallery";
import editor from "../src/pages/editor/editor.gallery";
import history from "../src/pages/history/history.gallery";
import keys from "../src/pages/keybindings/keybindings.gallery";
import { AppsStore } from "../src/pages/apps/store";
import { ChangelogStore } from "../src/pages/changelog/store";
import { CloudStore } from "../src/pages/cloud/store";
import { CodeRouterStore } from "../src/pages/coderouter/store";
import { EditorStore } from "../src/pages/editor/store";
import { HistoryStore } from "../src/pages/history/store";
import { KeybindingsStore } from "../src/pages/keybindings/store";

function client(state: BridgePageVariant): PageClient {
  const ops = fixtureOps(state);
  return {
    call: async <R>(op: string, params: unknown): Promise<R> => {
      if (!ops[op]) throw new Error(`Unexpected fixture operation: ${op}`);
      return (await ops[op](params, {})) as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

const cases = [
  { entry: apps, make: (c: PageClient) => new AppsStore(c), rows: (s: any) => s.catalog },
  { entry: changelog, make: (c: PageClient) => new ChangelogStore(c), rows: (s: any) => s.builds },
  { entry: cloud, make: (c: PageClient) => new CloudStore(c), rows: (s: any) => s.rows },
  { entry: coderouter, make: (c: PageClient) => new CodeRouterStore(c), rows: (s: any) => s.providers },
  { entry: history, make: (c: PageClient) => new HistoryStore(c), rows: (s: any) => s.entries },
  { entry: keys, make: (c: PageClient) => new KeybindingsStore(c), rows: (s: any) => s.rows },
];
for (const { entry, make, rows } of cases) {
  for (const [variant, count] of [
    ["empty", 0],
    ["loaded", 4],
    ["long-content", 40],
  ] as const) {
    test(`${entry.id}: ${variant} loads through the page store`, async () => {
      const store = make(client(entry.variants[variant]!));
      await store.start();
      const snapshot = store.getSnapshot();
      expect(snapshot.loading).toBe(false);
      expect(rows(snapshot)).toHaveLength(count);
    });
  }
  test(`${entry.id}: owner failures reach the page's error state`, async () => {
    const store = make(client(entry.variants.error!));
    await store.start();
    const snapshot = store.getSnapshot();
    expect(snapshot.loading).toBe(false);
    expect(
      "failed" in snapshot
        ? snapshot.failed
        : "error" in snapshot
          ? snapshot.error
          : "notice" in snapshot
            ? snapshot.notice?.kind === "failed"
              ? snapshot.notice.message
              : undefined
            : undefined,
    ).toContain("Sample owner");
  });
  test(`${entry.id}: a held reply keeps the page loading`, async () => {
    const store = make(client(entry.variants.loading!));
    void store.start();
    expect(store.getSnapshot().loading).toBe(true);
  });
}
for (const variant of ["empty", "loaded", "long-content", "error"] as const) {
  test(`editor: ${variant} uses the config input`, async () => {
    const store = new EditorStore(client(editor.variants[variant]!));
    await store.start();
    const state = store.getState();
    expect(state.phase).toBe(variant === "empty" ? "empty" : variant === "error" ? "failed" : "ready");
    if (variant === "loaded" || variant === "long-content") {
      let text = "";
      store.attachView({
        load: (doc) => {
          text = doc.text;
        },
        text: () => text,
        version: () => 1,
        setReadOnly: () => {},
      });
      expect(text).toContain("export const sample0");
    }
    store.dispose();
  });
}
