// The New Tab page's chat-derived lists, kept at the cost of the chats that changed (sessionList.ts
// `FolderRecency`, newTabModel.ts `RecentChats`), give what sorting every chat again gives
// (`recentLocalFolders`, `recentFolders` of launchRows.ts `omnibarFolder`, `recentSessions`) after every change a chat
// list goes through: a working chat's event, a status flip, a chat archived, moved to another
// folder or back in time, a child waiting on the person, chats added and removed.
import { expect, test } from "bun:test";
import { session } from "../src/gallery/fixtures/acpmux";
import { FolderRecency, recentFolders, recentLocalFolders } from "../src/agent-session/acpmux/sessionList";
import { omnibarFolder, omnibarFolders } from "../src/agent-session/acpmux/newtab/launchRows";
import { RecentChats, recentSessions } from "../src/agent-session/acpmux/newTabModel";
import { noteReplaced } from "../src/agent-session/acpmux/sessionIndex";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

/// A small seeded generator, so a failure names the run that found it.
function random(seed: number) {
  let state = seed >>> 0 || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x100000000;
  };
}

function chats(size: number, next: () => number): AcpmuxSessionEntry[] {
  return Array.from({ length: size }, (_, index) =>
    session({
      sessionId: `s${index}`,
      title: `chat ${index}`,
      cwd: `/Users/me/fun/p${Math.floor(next() * 12)}`,
      activityAt: 1_000_000 + Math.floor(next() * 1000) * 1000,
      ...(next() < 0.15 ? { peer: "box", host: "box" } : {}),
      ...(next() < 0.2 && index > 3 ? { spawnedBy: `s${Math.floor(next() * index)}` } : {}),
    }),
  );
}

/// One change to `list`'s chat at a random place, the way the pane lists one (in place).
function change(list: AcpmuxSessionEntry[], next: () => number, clock: { now: number }): AcpmuxSessionEntry[] {
  const at = Math.floor(next() * list.length);
  const entry = list[at]!;
  const roll = next();
  clock.now += 1000;
  const changed: AcpmuxSessionEntry =
    roll < 0.55
      ? { ...entry, activityAt: clock.now, updatedAt: clock.now }
      : roll < 0.7
        ? { ...entry, status: entry.status === "working" ? "idle" : "working" }
        : roll < 0.78
          ? { ...entry, archived: !entry.archived }
          : roll < 0.84
            ? { ...entry, cwd: `/Users/me/fun/p${Math.floor(next() * 12)}` }
            : roll < 0.9
              ? { ...entry, activityAt: (entry.activityAt ?? 0) - 500_000 }
              : roll < 0.95
                ? {
                    ...entry,
                    indicator: entry.indicator === "input" ? "done" : "input",
                  }
                : { ...entry, title: `${entry.title} again` };
  const updated = list.slice();
  updated[at] = changed;
  noteReplaced(list, updated, [at]);
  return updated;
}

test.each([1, 2, 3, 4, 5, 6, 7, 8])("kept lists equal a whole sort after each change (seed %i)", (seed) => {
  const next = random(seed);
  const clock = { now: 3_000_000 };
  let list = chats(seed % 2 ? 40 : 160, next);
  const local = new FolderRecency();
  const bar = new FolderRecency(omnibarFolder);
  const recent = new RecentChats(6, seed % 2 ? 8 : 64);
  const projects = [{ cwd: "/Users/me/fun/p3" }];
  for (let step = 0; step < 400; step += 1) {
    if (step % 97 === 50)
      list = [
        ...list,
        ...chats(3, next).map((entry, index) => ({
          ...entry,
          sessionId: `n${step}-${index}`,
        })),
      ];
    else if (step % 131 === 70) list = list.slice(2);
    else list = change(list, next, clock);
    expect(local.of(list)).toEqual(recentLocalFolders(list));
    expect(omnibarFolders(projects, bar.of(list))).toEqual(
      omnibarFolders(projects, recentFolders(list, omnibarFolder)),
    );
    expect(recent.of(list).map((entry) => entry.sessionId)).toEqual(
      recentSessions(list).map((entry) => entry.sessionId),
    );
    // A held chat's own fields (its title here) reach the rows.
    expect(recent.of(list).map((entry) => entry.title)).toEqual(recentSessions(list).map((entry) => entry.title));
  }
});

test("a working chat's event keeps the same lists when it changes nothing they show", () => {
  const next = random(9);
  const list = chats(200, next);
  const local = new FolderRecency();
  const recent = new RecentChats();
  const folders = local.of(list);
  const rows = recent.of(list);
  // The oldest chat of a folder whose newest is far newer: its event moves nothing either list shows.
  const order = recentSessions(list, list.length, false);
  const quiet = order.at(-1)!;
  const at = list.findIndex((entry) => entry.sessionId === quiet.sessionId);
  const updated = list.slice();
  updated[at] = { ...quiet, activityAt: (quiet.activityAt ?? 0) + 1 };
  noteReplaced(list, updated, [at]);
  expect(recent.of(updated)).toBe(rows);
  expect(local.of(updated)).toEqual(folders);
});
