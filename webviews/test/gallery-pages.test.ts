// The fixtures cross the real page stores' input contracts, without a browser process.
import { expect, test } from "bun:test";
import { fixtureOps } from "../src/gallery/frame/pageReplies";
import type { BridgePageVariant } from "../src/gallery/format";
import type { PageClient } from "../src/pages/shared/pageClient";
import apps from "../src/pages/apps/apps.gallery";
import changelog from "../src/pages/changelog/changelog.gallery";
import cloud from "../src/pages/cloud/cloud.gallery";
import coderouter from "../src/pages/coderouter/coderouter.gallery";
import { AppsStore } from "../src/pages/apps/store";
import { ChangelogStore } from "../src/pages/changelog/store";
import { CloudStore } from "../src/pages/cloud/store";
import { CodeRouterStore } from "../src/pages/coderouter/store";

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
