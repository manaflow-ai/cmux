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
  const settled = pager.settle(held);
  expect(settled).toHaveLength(COUNT - 1);
  expect(settled.filter((row) => row.sessionId === "s250")).toEqual([changed]);
  expect(settled.some((row) => row.sessionId === "s260")).toBe(false);
});
