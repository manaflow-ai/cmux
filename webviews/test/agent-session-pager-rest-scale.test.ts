// l10n-allow-file: fixture IDs and comments are not shipped UI.
// A 3,000-chat list arrives in 200-row pages. Its client should scan the already-held
// IDs once, then maintain the identity index while later pages and live notices arrive.
import { expect, test } from "bun:test";
import { SessionPager } from "../src/agent-session/acpmux/sessionPages";

type Session = { sessionId: string; updatedAt: number };
const COUNT = 3_000;
const PAGE = 200;
const sessions: Session[] = Array.from({ length: COUNT }, (_, n) => ({
  sessionId: `s${n}`,
  updatedAt: COUNT - n,
}));

function daemon(onPage?: (from: number) => Promise<void>) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const pager = new SessionPager<Session>(async (method, params) => {
    calls.push({ method, params });
    const from = typeof params.cursor === "string" ? Number(params.cursor) : 0;
    const end = Math.min(from + PAGE, COUNT);
    // Snapshot first, then allow a notification while the reply is in flight.
    const answer = {
      sessions: sessions.slice(from, end),
      ...(end < COUNT ? { nextCursor: String(end) } : {}),
    };
    await onPage?.(from);
    return answer;
  });
  return { pager, calls };
}

test("3,000 sessions read all pages with a single held-ID scan", async () => {
  const { pager, calls } = daemon();
  const first = await pager.first();
  expect(first).toBeDefined();
  if (!first) return;
  let held = first.sessions.slice();
  let scans = 0;
  let previouslyHeldRowsVisited = 0;
  const complete = await pager.rest(
    first,
    () => {
      scans += 1;
      previouslyHeldRowsVisited += held.length;
      return held;
    },
    (fresh) => {
      held = [...held, ...fresh];
    },
  );
  expect(complete).toBe(true);
  expect(calls).toHaveLength(COUNT / PAGE);
  expect(held).toHaveLength(COUNT);
  expect(new Set(held.map((row) => row.sessionId)).size).toBe(COUNT);
  // Red on the previous implementation: 14 held() scans / 21,000 entries.
  expect(scans).toBe(1);
  expect(previouslyHeldRowsVisited).toBe(PAGE);
});

test("a newer session_changed and a purge beat an in-flight stale page", async () => {
  let announcePage!: () => void;
  let releasePage!: () => void;
  const pageRequested = new Promise<void>((resolve) => (announcePage = resolve));
  const heldPage = new Promise<void>((resolve) => (releasePage = resolve));
  const { pager } = daemon(async (from) => {
    if (from === PAGE) {
      announcePage();
      await heldPage;
    }
  });
  const first = await pager.first();
  expect(first).toBeDefined();
  if (!first) return;
  let held = first.sessions.slice();
  const read = pager.rest(
    first,
    () => held,
    (fresh) => {
      held = [...held, ...fresh];
    },
  );
  await pageRequested;
  // direct.ts applies the notice immediately; the late page still carries old s250.
  const changed = { sessionId: "s250", updatedAt: 9_999 };
  pager.changedSession(changed);
  held = [...held, changed];
  pager.purgedSession("s260");
  releasePage();

  expect(await read).toBe(true);
  expect(held).toHaveLength(COUNT - 1);
  expect(held.filter((row) => row.sessionId === "s250")).toEqual([changed]);
  expect(held.some((row) => row.sessionId === "s260")).toBe(false);
});

// Once the list is whole the pane's own list takes every change: the pager keeps none of them. Kept,
// every chat ever closed stayed in `purged` for the pane's life (test/state-growth.test.ts, session-churn).
test("after the list is whole, changes and purges are not kept", async () => {
  const { pager } = daemon();
  const first = await pager.first();
  if (!first) throw new Error("no first page");
  let held = first.sessions.slice();
  const add = (fresh: Session[]) => void (held = [...held, ...fresh]);
  expect(await pager.rest(first, () => held, add)).toBe(true);
  pager.done(first.run);
  for (let n = 0; n < 1_000; n++) {
    pager.changedSession({ sessionId: `new${n}`, updatedAt: n });
    pager.purgedSession(`new${n}`);
  }
  const kept = pager as unknown as { purged: Set<string>; changed: Map<string, Session> };
  expect([kept.purged.size, kept.changed.size]).toEqual([0, 0]);
  // A newer list keeps its own changes until it is whole, and an older list's `done` does not end them.
  const again = await pager.first();
  pager.purgedSession("s5");
  pager.done(first.run);
  expect(pager.settle(again!.sessions).some((row) => row.sessionId === "s5")).toBe(false);
  pager.done(again!.run);
  expect(kept.purged.size).toBe(0);
});

// The open path reads the whole list for a chat past the first page; a lagged watch's reread can start and finish
// while that read is out. A chat closed after the reread finished must not come back with the older reply
// (review of the pager's `done`: it stopped keeping purges, and the whole list reinstalled the chat).
test("a whole-list read still out keeps the purges a newer, finished list stopped keeping", async () => {
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  const rows = [
    { sessionId: "a", updatedAt: 3 },
    { sessionId: "b", updatedAt: 2 },
  ];
  const pager = new SessionPager<Session>(async (method, params) => {
    if (method === "_acpmux/watch" && params.limit === undefined) await held;
    return { sessions: rows.slice() };
  });
  const whole = pager.settledWhole();
  const reread = await pager.first();
  pager.done(reread!.run);
  pager.purgedSession("b");
  release();
  expect((await whole).map((row) => row.sessionId)).toEqual(["a"]);
  // Once it landed, nothing is kept any more.
  pager.purgedSession("a");
  const kept = pager as unknown as { purged: Set<string> };
  expect(kept.purged.size).toBe(0);
});
