// This Mac's chat folders, newest first, kept as the chat list changes (sessionList.ts
// `FolderRecency`) instead of sorting every chat on each event: Leo, 2026-11-18, "typing in the
// composer still slow 😞 there must be a lot of open stuff?" (bench/session-scale-typing.bench.ts).
// Whatever the changes, it lists what `recentLocalFolders` lists, and the same array while the order holds.
import { expect, test } from "bun:test";
import { omnibarFolder } from "../src/agent-session/acpmux/newtab/launchRows";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import {
  type AcpmuxSessionEntry,
  FolderRecency,
  recentFolders,
  recentLocalFolders,
  sessionEntry,
} from "../src/agent-session/acpmux/sessionList";

/// A small seeded generator, so a failure replays.
function random(seed: number) {
  let state = seed;
  return (below: number) => {
    state = (state * 1_103_515_245 + 12_345) % 2_147_483_648;
    return state % below;
  };
}

function chat(index: number, fields: Record<string, unknown> = {}): AcpmuxSessionEntry {
  return sessionEntry({
    sessionId: `s${index}`,
    title: `Chat ${index}`,
    harness: "claude",
    status: "idle",
    cwd: `/Users/me/code/p${index % 23}`,
    updatedAt: 1_000 + index,
    ...(index % 9 === 4 ? { peer: "studio", host: "studio" } : {}),
    ...fields,
  });
}

/// Replaces entry `at` in place, as the pane's list does (sessionIndex.ts `noteReplaced`).
function replaced(list: readonly AcpmuxSessionEntry[], at: number, entry: AcpmuxSessionEntry) {
  const next = list.slice();
  next[at] = entry;
  noteReplaced(list, next, [at]);
  return next;
}

test("lists what recentLocalFolders and the omnibar's folders list through any change", () => {
  for (const seed of [1, 2, 3, 4, 5]) {
    const roll = random(seed);
    let clock = 5_000;
    let list: readonly AcpmuxSessionEntry[] = Array.from({ length: 200 }, (_, index) => chat(index));
    const recency = new FolderRecency();
    const omnibar = new FolderRecency(omnibarFolder);
    expect([...recency.of(list)]).toEqual(recentLocalFolders(list));
    for (let step = 0; step < 2_000; step++) {
      const at = roll(list.length);
      const index = Number(list[at]!.sessionId.slice(1));
      const kind = roll(20);
      // Mostly a chat working now; now and then an equal time, an older one, a move, another machine, or a new chat.
      const fields =
        kind < 12
          ? { updatedAt: (clock += 1 + roll(3)) }
          : kind < 14
            ? { updatedAt: list[roll(list.length)]!.updatedAt }
            : kind < 15
              ? { updatedAt: 500 + roll(400) }
              : kind < 16
                ? { cwd: `/Users/me/code/p${roll(31)}`, updatedAt: (clock += 1) }
                : kind < 17
                  ? { peer: "studio", host: "studio", updatedAt: (clock += 1) }
                  : { title: `Renamed ${step}`, updatedAt: list[at]!.updatedAt };
      list =
        kind === 19 && step % 7 === 0
          ? [...list, chat(list.length + 1_000, { updatedAt: (clock += 1) })]
          : replaced(list, at, chat(index, { ...fields }));
      expect([...recency.of(list)]).toEqual(recentLocalFolders(list));
      expect([...omnibar.of(list)]).toEqual(recentFolders(list, omnibarFolder));
    }
  }
});

test("hands back the same array while the order holds", () => {
  let list: readonly AcpmuxSessionEntry[] = Array.from({ length: 100 }, (_, index) => chat(index));
  const recency = new FolderRecency();
  list = replaced(list, 5, chat(5, { updatedAt: 9_000 }));
  const first = recency.of(list);
  // The front folder's chat working again, and a renamed chat: the same order.
  list = replaced(list, 5, chat(5, { updatedAt: 9_001 }));
  expect(recency.of(list)).toBe(first);
  list = replaced(list, 7, chat(7, { title: "Renamed" }));
  expect(recency.of(list)).toBe(first);
  // Another folder's chat working moves that folder to the front: a new array.
  list = replaced(list, 6, chat(6, { updatedAt: 9_002 }));
  const moved = recency.of(list);
  expect(moved).not.toBe(first);
  expect(moved[0]).toBe("/Users/me/code/p6");
  expect([...moved]).toEqual(recentLocalFolders(list));
});
