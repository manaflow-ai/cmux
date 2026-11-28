// The New Tab page's chat list at Leo's scale (1,100 to 11k chats). RecentChats (newTabModel.ts) rebuilt its held
// chats with a sort of every chat each time the list's length changed (a chat started or gone); `recentTop` keeps the
// best `room` in one pass. `leaders` (leads.ts) ran on every render; it is now kept per chat-list array.
// Correctness: the old sort (`recentTopBySort`) and the uncached `leadersUncached` are the oracles on random lists.
// Speed: old against new on one list, interleaved in one process, and new at 10x.
import { describe, expect, test } from "bun:test";
import { session } from "../src/gallery/fixtures/acpmux";
import { RecentChats, recentSessions, recentTop, recentTopBySort } from "../src/agent-session/acpmux/newTabModel";
import { leaders, leadersUncached } from "../src/agent-session/acpmux/leads";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

function chat(g: Gen, i: number): AcpmuxSessionEntry {
  const roll = g.next();
  return session({
    sessionId: `s${g.int(0, 3) === 0 ? g.int(0, i) : i}`,
    title: `chat ${i}`,
    // Few distinct times, so ties on time (broken by id, or not at all for a repeated id) are common.
    activityAt: 1_000_000 + g.int(0, 20) * 1000,
    ...(g.bool(0.15) ? { indicator: "input" } : {}),
    ...(g.bool(0.1) ? { status: "closed" } : {}),
    ...(g.bool(0.1) ? { archived: true } : {}),
    ...(g.bool(0.1) ? { unsent: true } : {}),
    ...(roll < 0.4 ? { tags: { "lane.reportsTo": `s${g.int(0, Math.max(0, i))}` } } : {}),
    ...(g.bool(0.15) ? { spawnedBy: `s${g.int(0, i)}` } : {}),
    ...(g.bool(0.2) ? { peer: "box", host: "box" } : {}),
  });
}

const list = (g: Gen, n: number) => Array.from({ length: n }, (_, i) => chat(g, i));

/// A realistic list: distinct ids and times, a tenth of the chats lanes reporting to 50 leaders.
const scale = (n: number) =>
  Array.from({ length: n }, (_, i) =>
    session({
      sessionId: `s${i}`,
      title: `chat ${i}`,
      activityAt: 1_000_000 + ((i * 7919) % 1_000_000) * 1000,
      ...(i % 10 ? {} : { tags: { "lane.reportsTo": `s${i % 50}` } }),
    }),
  );

describe("RecentChats rebuild", () => {
  test("recentTop gives the sort's chats, in its order, on random lists", () => {
    forSeeds(2000, (g) => {
      const sessions = list(g, g.int(0, 120));
      const room = g.pick([0, 1, 6, 8, 64]);
      const got = recentTop(sessions, room);
      const want = recentTopBySort(sessions, room);
      expect(got.complete).toBe(want.complete);
      expect(got.top.map((e) => e.sessionId)).toEqual(want.top.map((e) => e.sessionId));
      for (let i = 0; i < want.top.length; i++) expect(got.top[i]).toBe(want.top[i]!);
    });
  });

  test("the rows after chats come and go equal recentSessions of the whole list", () => {
    forSeeds(300, (g) => {
      const recent = new RecentChats(6, g.pick([8, 64]));
      let sessions = list(g, g.int(0, 80));
      for (let step = 0; step < 6; step++) {
        sessions = g.bool() ? [...sessions, ...list(g, g.int(1, 5))] : sessions.slice(g.int(1, 4));
        expect(recent.of(sessions).map((e) => e.sessionId)).toEqual(recentSessions(sessions).map((e) => e.sessionId));
      }
    });
  });

  test("a new chat in an 11k list: faster than the sort, linear at 10x", () => {
    const base = scale(11_000);
    const grown = [...base, session({ sessionId: "new", activityAt: 9e12 })];
    expectSpeedup(
      "recentChats.rebuild_11k",
      11_000,
      () => recentTopBySort(grown, 64),
      () => recentTop(grown, 64),
      { minSpeedup: 2, budgetMs: 25 },
    );
    expectGrowth(
      "recentChats.rebuild",
      1_100,
      (n) => {
        const sessions = scale(n);
        return () => recentTop(sessions, 64);
      },
      { maxRatio: 30, runs: 9 },
    );
  });
});

describe("leaders", () => {
  test("equal to working them out again, on random lists", () => {
    forSeeds(2000, (g) => {
      const sessions = list(g, g.int(0, 80));
      const want = leadersUncached(sessions);
      for (const got of [leaders(sessions), leaders(sessions)]) {
        expect(got.length).toBe(want.length);
        got.forEach((lead, i) => {
          expect(lead.entry.sessionId).toBe(want[i]!.entry.sessionId);
          expect(lead.reports.map((r) => r.sessionId)).toEqual(want[i]!.reports.map((r) => r.sessionId));
        });
      }
      // A new list (a chat changed) is worked out again, not served from the old one.
      const changed = [...sessions, ...list(g, 3)];
      expect(leaders(changed).map((l) => l.entry.sessionId)).toEqual(
        leadersUncached(changed).map((l) => l.entry.sessionId),
      );
    });
  });

  test("a render with the same 11k list: flat, far under working it out again", () => {
    const sessions = scale(11_000);
    leaders(sessions);
    expectSpeedup(
      "leaders.render_11k",
      11_000,
      () => leadersUncached(sessions),
      () => leaders(sessions),
      {
        minSpeedup: 20,
        budgetMs: 1,
      },
    );
    expectGrowth(
      "leaders.render",
      11_000,
      (n) => {
        const sessions = scale(n);
        leaders(sessions);
        return () => leaders(sessions);
      },
      { maxRatio: 3 },
    );
  });
});
