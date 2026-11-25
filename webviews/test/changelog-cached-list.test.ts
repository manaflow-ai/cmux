// A warm open of What's New draws the list the host kept on disk at once, never "Loading…" while
// the network answers; the network's list then replaces it quietly (store.ts loadCachedThenFresh).
import { expect, test } from "bun:test";
import { ChangelogStore } from "../src/pages/changelog/store";
import type { ListResult, ReleaseNotes } from "../src/pages/changelog/types";

function notes(build: string): ReleaseNotes {
  return {
    build,
    shortVersion: `1.0.0-nightly.${build}`,
    date: "2026-11-10",
    highlights: [],
    summary: [{ group: "new" as const, title: `Change in ${build}` }],
    changes: [],
  };
}

function list(builds: string[], current = builds[0]): ListResult {
  return {
    current,
    builds: builds.map((build) => ({
      build,
      shortVersion: `1.0.0-nightly.${build}`,
      date: "2026-11-10",
      highlights: 0,
    })),
  };
}

/** A host whose disk list answers at once and whose network list waits until `release`. */
function host(disk: ListResult, network: ListResult) {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const calls: { op: string; cached: boolean }[] = [];
  const client = {
    async call<R>(op: string, params: unknown): Promise<R> {
      const p = (params ?? {}) as { cached?: boolean; build?: string };
      calls.push({ op, cached: p.cached === true });
      if (op === "cmux.changelog.list") {
        if (p.cached) return disk as R;
        await gate;
        return network as R;
      }
      if (op === "cmux.changelog.get") return notes(String(p.build)) as R;
      if (op === "cmux.changelog.installable") return { installs: false } as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
  };
  return { client: client as never, calls, release };
}

test("a warm open draws the cached list and its notes before the network answers", async () => {
  const h = host(list(["101", "100"]), list(["102", "101", "100"]));
  const store = new ChangelogStore(h.client);
  const seen: boolean[] = [];
  store.subscribe(() => seen.push(store.getSnapshot().loading));
  await store.start();
  const shown = store.getSnapshot();
  // Drawn with the network still waiting: no loading frame after the first one.
  expect(shown.loading).toBe(false);
  expect(shown.builds.map((b) => b.build)).toEqual(["101", "100"]);
  expect(shown.notes?.build).toBe("101");
  expect(h.calls.filter((c) => c.op === "cmux.changelog.list").map((c) => c.cached)).toEqual([true, false]);

  h.release();
  await store.refreshed;
  const fresh = store.getSnapshot();
  expect(fresh.builds.map((b) => b.build)).toEqual(["102", "101", "100"]);
  expect(fresh.current).toBe("102");
  // The running build changed, but the build the reader is on stays selected.
  expect(fresh.selected).toBe("101");
  expect(seen).not.toContain(true);
});

test("without a list on disk the page waits for the network as before", async () => {
  const h = host(list([]), list(["7"]));
  const store = new ChangelogStore(h.client);
  const started = store.start();
  await Promise.resolve();
  expect(store.getSnapshot().loading).toBe(true);
  h.release();
  await started;
  expect(store.getSnapshot()).toMatchObject({ loading: false, selected: "7" });
});

test("a network failure after a cached draw keeps the cached list", async () => {
  const disk = list(["5"]);
  const client = {
    async call<R>(op: string, params: unknown): Promise<R> {
      const p = (params ?? {}) as { cached?: boolean; build?: string };
      if (op === "cmux.changelog.list") {
        if (p.cached) return disk as R;
        throw new Error("offline");
      }
      if (op === "cmux.changelog.get") return notes(String(p.build)) as R;
      return {} as R;
    },
    async subscribe() {
      return () => {};
    },
  };
  const store = new ChangelogStore(client as never);
  await store.start();
  await store.refreshed;
  expect(store.getSnapshot()).toMatchObject({ loading: false, selected: "5" });
  expect(store.getSnapshot().failed).toBeUndefined();
  expect(store.getSnapshot().builds.map((b) => b.build)).toEqual(["5"]);
});
