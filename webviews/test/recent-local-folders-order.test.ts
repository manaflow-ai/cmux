// `recentLocalFolders` keeps each folder's newest chat in one pass and sorts only the folders, so a
// change of one chat no longer sorts every listed chat (bench/session-scale-scroll.bench.ts). Its
// order is the one a stable newest-first sort of the chats gave, ties included.
import { expect, test } from "bun:test";
import { recentLocalFolders, sessionEntry, type AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

/// What the function returned before: a stable newest-first sort of this Mac's listed chats, then
/// each folder at its first chat.
function bySort(sessions: readonly AcpmuxSessionEntry[], limit = Infinity): string[] {
  const local = sessions.filter((session) => {
    const cwd = session.cwd?.replace(/\/+$/, "");
    if (!cwd || cwd === "~" || cwd.includes("/agent-home")) return false;
    return !session.peer && (!session.hostKind || session.hostKind === "local");
  });
  const sorted = [...local].sort(
    (left, right) => (right.activityAt ?? right.updatedAt ?? 0) - (left.activityAt ?? left.updatedAt ?? 0),
  );
  const folders = new Set<string>();
  for (const session of sorted) {
    folders.add(session.cwd!.replace(/\/+$/, ""));
    if (folders.size >= limit) break;
  }
  return [...folders];
}

test("folders come newest first, each once, in the order a sort of every chat gave", () => {
  // A seeded generator: the same chats every run, with many equal times so ties are exercised.
  let seed = 7;
  const next = () => (seed = (seed * 48_271) % 2_147_483_647);
  const sessions = Array.from({ length: 3000 }, (_, index) =>
    sessionEntry({
      sessionId: `s-${index}`,
      cwd: `/Users/me/code/p${next() % 120}${index % 7 === 0 ? "/" : ""}`,
      updatedAt: 1_000 + (next() % 50),
      status: "idle",
      ...(index % 11 === 0 ? { peer: "other-mac" } : {}),
      ...(index % 13 === 0 ? { hostKind: "cloud", host: "vm-1" } : {}),
    }),
  );
  expect(sessions.length).toBe(3000);
  const expected = bySort(sessions);
  expect(expected.length).toBeGreaterThan(50);
  expect(recentLocalFolders(sessions)).toEqual(expected);
  expect(recentLocalFolders(sessions, 5)).toEqual(bySort(sessions, 5));
});
