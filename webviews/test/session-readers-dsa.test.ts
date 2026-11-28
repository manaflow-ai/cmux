// The pane's whole-list readers kept as the list changes (RFD 0199 section 7, sessionReaders.ts): the Steer queue
// (`SteerQueueReader`), the Chief dock (`ChiefRanking`) and the New Tab's remembered folders (newtab/recentProject.ts
// through `FolderRecency`). Correctness: today's full pass is the oracle (steerQueue/model.ts `steerQueue`,
// `chiefRankedBySort`, `recentLocalFolders`) on seeded edits of random lists: in-place replacements recorded as
// direct.ts records them, same-length copies with no record, chats added and gone, parents archived and children
// moved. Work: entries read per in-place change, counted (no wall time), at most 2x from 1k to 10k chats. Speed: old
// and new per change on one 10k list, interleaved, and new at 10x.
import { beforeEach, describe, expect, test } from "bun:test";
import { fleetListedSession } from "../src/agent-session/acpmux/mockFixture";
import { rememberRecentFolders, resetRecentProjectForTests } from "../src/agent-session/acpmux/newtab/recentProject";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import {
  FolderRecency,
  localFolder,
  recentLocalFolders,
  sessionEntry,
  type AcpmuxSessionEntry,
} from "../src/agent-session/acpmux/sessionList";
import {
  ChiefRanking,
  SteerQueueReader,
  chiefRankedBySort,
  readerReads,
} from "../src/agent-session/acpmux/sessionReaders";
import { STALLED_MS, steerQueue } from "../src/agent-session/acpmux/steerQueue/model";
import type { SteerAct } from "../src/agent-session/acpmux/steerQueue/log";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

const NOW = Date.UTC(2026, 10, 27, 12, 0);

function randomEntry(g: Gen, id: number, ids: number): AcpmuxSessionEntry {
  const entry: Record<string, unknown> = {
    sessionId: `s${id}`,
    displayTitle: g.bool(0.8) ? `chat ${id}` : "",
    cwd: g.pick([undefined, "~", "/repo/a", "/repo/b", "/repo/c/", "/repo/d", "/tmp/x"]),
    indicator: g.pick([undefined, "input", "working", "failed", "lost", "done", "idle"]),
    status: g.pick([undefined, undefined, "running", "waiting", "idle"]),
  };
  // Times collide often, so ties test the list's own order.
  if (g.bool(0.9)) entry.updatedAt = NOW - g.int(0, 12) * 60_000;
  if (g.bool(0.3)) entry.activityAt = NOW - g.int(0, 12) * 60_000;
  if (g.bool(0.3)) entry.unread = true;
  if (g.bool(0.1)) entry.archived = true;
  if (g.bool(0.05)) entry.side = true;
  if (g.bool(0.05)) entry.unsent = true;
  if (g.bool(0.1)) entry.pendingPermissions = 1;
  if (g.bool(0.05)) entry.peer = "peer-a";
  if (g.bool(0.05)) entry.hostKind = "cloud";
  if (g.bool(0.25) && ids > 1) entry.spawnedBy = `s${g.int(0, ids - 1)}`;
  if (g.bool(0.05)) entry.lane = "failed";
  return entry as AcpmuxSessionEntry;
}

type Edit = { list: AcpmuxSessionEntry[] };

/// The next list: mostly one or a few chats replaced in place and recorded, as direct.ts makes them.
function edit(g: Gen, list: AcpmuxSessionEntry[], next: () => number): AcpmuxSessionEntry[] {
  const roll = g.int(0, 99);
  if (roll < 70 && list.length > 0) {
    const changed = Array.from({ length: g.int(1, 3) }, () => g.int(0, list.length - 1));
    const out = list.slice();
    for (const at of changed) {
      const fresh = randomEntry(g, 0, list.length);
      const old = out[at]!;
      // Usually the same parent link (a status tick); sometimes another.
      out[at] = { ...fresh, sessionId: old.sessionId, spawnedBy: g.bool(0.85) ? old.spawnedBy : fresh.spawnedBy };
    }
    if (g.bool(0.9)) noteReplaced(list, out, changed);
    return out;
  }
  if (roll < 80) return [...list, randomEntry(g, next(), list.length + 1)];
  if (roll < 90 && list.length > 0) return list.filter((_, at) => at !== g.int(0, list.length - 1));
  if (roll < 95 && list.length > 0) {
    // A duplicate id.
    const out = list.slice();
    const at = g.int(0, out.length - 1);
    out[at] = { ...randomEntry(g, 0, list.length), sessionId: list[g.int(0, list.length - 1)]!.sessionId };
    noteReplaced(list, out, [at]);
    return out;
  }
  return list.slice();
}

function runEdits(seeds: number, check: (g: Gen, list: AcpmuxSessionEntry[]) => void, setup: () => void = () => {}) {
  forSeeds(seeds, (g) => {
    setup();
    let ids = g.int(0, 40);
    let list = Array.from({ length: ids }, (_, id) => randomEntry(g, id, ids));
    check(g, list);
    for (let step = 0; step < 25; step++) {
      list = edit(g, list, () => ids++);
      check(g, list);
    }
  });
}

describe("session list readers against today's full pass", () => {
  test("SteerQueueReader gives steerQueue's items for every edit, clock and log", () => {
    let reader = new SteerQueueReader();
    runEdits(
      1500,
      (g, list) => {
        const now = NOW + g.int(-2, 12) * 60_000 + g.pick([0, STALLED_MS, -1, 1]);
        const log: SteerAct[] = list
          .filter(() => g.bool(0.1))
          .map((entry) => ({ sessionId: entry.sessionId, act: "steer", at: NOW }) as unknown as SteerAct);
        expect(reader.read({ sessions: list, now, log })).toEqual(steerQueue({ sessions: list, now, log }));
      },
      () => (reader = new SteerQueueReader()),
    );
  });

  test("ChiefRanking gives the sorted dock's cards and count for every edit and open chat", () => {
    let ranking = new ChiefRanking();
    runEdits(
      1500,
      (g, list) => {
        const currentId = g.pick([undefined, `s${g.int(0, list.length + 2)}`, list[0]?.sessionId]);
        const cards = g.pick([4, 1, 12]);
        const got = ranking.read(list, currentId, cards);
        const want = chiefRankedBySort(list, currentId, cards);
        expect(got.attention).toBe(want.attention);
        expect(got.cards.length).toBe(want.cards.length);
        got.cards.forEach((entry, at) => expect(entry).toBe(want.cards[at]!));
      },
      () => (ranking = new ChiefRanking()),
    );
  });

  describe("rememberRecentFolders", () => {
    let store = new Map<string, string>();
    beforeEach(() => {
      store = new Map();
      (globalThis as { localStorage?: unknown }).localStorage = {
        getItem: (key: string) => store.get(key) ?? null,
        setItem: (key: string, value: string) => void store.set(key, value),
      };
    });

    test("keeps recentLocalFolders' first twelve for every edit", () => {
      let expected: string | undefined;
      runEdits(
        800,
        (_, list) => {
          rememberRecentFolders({ origin: "local", sessions: list });
          const folders = recentLocalFolders(list, 12);
          if (folders.length > 0) expected = JSON.stringify(folders);
          expect(store.get("cmux.acpmux.newTab.recentFolders.v1")).toBe(expected);
        },
        () => {
          resetRecentProjectForTests();
          store.clear();
          expected = undefined;
        },
      );
    });
  });
});

const row = (index: number, fields: Record<string, unknown> = {}) =>
  sessionEntry({ ...(fleetListedSession(index, NOW) as Record<string, unknown>), ...fields } as never);

/// A fleet-shaped list of `size` chats and a step that replaces one chat in place, as a status tick does. The lists
/// are made ahead, so a timed step is the reader's work alone; each is recorded (`noteReplaced`) as it is read, as
/// direct.ts records a list as it makes it.
function fleet(size: number, steps = 260) {
  const first = Array.from({ length: size }, (_, index) =>
    row(
      index,
      index % 7 === 0
        ? { status: "running", indicator: "working" }
        : index % 11 === 0
          ? { unread: true, indicator: "done" }
          : {},
    ),
  );
  const lists: AcpmuxSessionEntry[][] = [first];
  const changed: number[] = [];
  for (let round = 0; round < steps; round++) {
    const from = lists[round]!;
    const at = (round * 7919) % from.length;
    const index = Number(from[at]!.sessionId.slice("listed-".length));
    const list = from.slice();
    list[at] = row(index, {
      status: round % 2 ? "running" : "idle",
      indicator: round % 2 ? "working" : "done",
      unread: round % 3 === 0,
      updatedAt: NOW + round,
    });
    lists.push(list);
    changed.push(at);
  }
  let round = 0;
  return {
    get list() {
      return lists[round]!;
    },
    step() {
      if (round >= steps) throw new Error("fleet: out of steps");
      noteReplaced(lists[round]!, lists[round + 1]!, [changed[round]!]);
      round += 1;
      return lists[round]!;
    },
  };
}

/// Entries read per in-place change, after the first read of the list.
function readsPerChange(size: number, read: (list: readonly AcpmuxSessionEntry[]) => void): number {
  const chats = fleet(size);
  read(chats.list);
  const rounds = 200;
  const start = readerReads.count;
  for (let round = 0; round < rounds; round++) read(chats.step());
  return (readerReads.count - start) / rounds;
}

describe("work per change", () => {
  test("entries read per in-place change stay flat from 1k to 10k chats", () => {
    const steer = (size: number) => {
      const reader = new SteerQueueReader();
      return readsPerChange(size, (sessions) => reader.read({ sessions, now: NOW }));
    };
    const chief = (size: number) => {
      const ranking = new ChiefRanking();
      return readsPerChange(size, (sessions) => ranking.read(sessions, "listed-3", 4));
    };
    const folders = (size: number) => {
      let reads = 0;
      const recency = new FolderRecency((session) => {
        reads += 1;
        return localFolder(session);
      });
      const chats = fleet(size);
      recency.of(chats.list);
      reads = 0;
      for (let round = 0; round < 200; round++) recency.of(chats.step());
      return reads / 200;
    };
    for (const [name, count] of [
      ["steerQueue", steer],
      ["chiefDock", chief],
      ["recentFolders", folders],
    ] as const) {
      const small = count(1_000);
      const large = count(10_000);
      console.log(`dsa-reads name=${name} n=1000 per_change=${small.toFixed(2)} per_change_10x=${large.toFixed(2)}`);
      // One change reads the changed chat and the rows drawn (nine at most), not the list.
      expect(large).toBeLessThan(30);
      expect(large).toBeLessThanOrEqual(Math.max(2 * small, small + 2));
    }
  });
});

describe("per change at fleet size", () => {
  test("Steer queue, Chief dock and remembered folders: faster than the full pass at 10k, flat at 10x", () => {
    const pair = (
      name: string,
      old: (list: readonly AcpmuxSessionEntry[]) => unknown,
      make: () => (list: readonly AcpmuxSessionEntry[]) => unknown,
      minSpeedup: number,
    ) => {
      const a = fleet(10_000);
      const b = fleet(10_000);
      const next = make();
      next(b.list);
      expectSpeedup(
        `sessionReaders.${name}_10k`,
        10_000,
        () => old(a.step()),
        () => next(b.step()),
        {
          minSpeedup,
          budgetMs: 1,
          runs: 41,
        },
      );
      expectGrowth(
        `sessionReaders.${name}`,
        1_000,
        (n) => {
          const chats = fleet(n);
          const read = make();
          read(chats.list);
          return () => read(chats.step());
        },
        { maxRatio: 3, runs: 41 },
      );
    };
    pair(
      "steer_queue",
      (sessions) => steerQueue({ sessions, now: NOW }),
      () => {
        const reader = new SteerQueueReader();
        return (sessions) => reader.read({ sessions, now: NOW });
      },
      5,
    );
    pair(
      "chief_dock",
      (sessions) => chiefRankedBySort(sessions, "listed-3", 4),
      () => {
        const ranking = new ChiefRanking();
        return (sessions) => ranking.read(sessions, "listed-3", 4);
      },
      5,
    );
    pair(
      "recent_folders",
      (sessions) => recentLocalFolders(sessions, 12),
      () => {
        const recency = new FolderRecency(localFolder);
        return (sessions) => recency.of(sessions).slice(0, 12);
      },
      5,
    );
  });
});
