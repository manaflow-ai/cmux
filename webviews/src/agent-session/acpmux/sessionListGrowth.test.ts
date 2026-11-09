// l10n-allow-file: test fixtures.
// One session's change costs the same at any list size (Leo, 2026-11-04: "never ... acceptable ...
// linear time growth degradation"): the pane's per-snapshot projections of the session list read
// the changed session, not every listed one. Counted, not timed, so a busy runner cannot fail it:
// each listed entry counts the reads of its fields other than its id (an id lookup per entry is how
// a projection finds what changed), and one change at 20,000 sessions must read about what it reads
// at 200. bench/update-one.bench.ts times the same paths in the real pane.
import { expect, test } from "bun:test";
import { folderFields, recentLocalFolders, sessionEntry, SessionsBy, type AcpmuxSessionEntry } from "./sessionList";
import { SessionHoverStore } from "./started/sessionHover";
import { SubsessionStore } from "./subagents/subsessions";

let reads = 0;
/// Entry `index` of a large list, counting every read of a field but its id.
function counted(index: number, fields: Record<string, unknown> = {}): AcpmuxSessionEntry {
  const entry = sessionEntry({
    sessionId: `s${index}`,
    title: `Chat ${index}`,
    name: `chat-${index}`,
    harness: "claude",
    status: "idle",
    cwd: `/Users/me/code/p${index % 40}`,
    updatedAt: 1_000_000 + index,
    createdAt: 1_000_000 + index,
    ...(index % 7 === 3 ? { startedBy: `s${index - 1}` } : {}),
    ...fields,
  });
  return new Proxy(entry, {
    get(target, key, receiver) {
      if (key !== "sessionId") reads++;
      return Reflect.get(target, key, receiver);
    },
  });
}

/// A turn starting and a rename, in the middle of the list.
const BUSY = { status: "running", title: "Renamed" };

/// The reads one change (`fields` of the middle session) costs `project` at `size` listed sessions,
/// after it has seen the list once.
function readsForOneChange(
  size: number,
  project: (sessions: readonly AcpmuxSessionEntry[]) => void,
  fields: Record<string, unknown> = BUSY,
): number {
  const sessions = Array.from({ length: size }, (_, index) => counted(index));
  project(sessions);
  const changed = sessions.slice();
  changed[Math.floor(size / 2)] = counted(Math.floor(size / 2), fields);
  reads = 0;
  project(changed);
  return reads;
}

/// Reads at the large size over reads at the small one: 1 is flat; a whole-list pass is 100.
function growth(
  project: () => (sessions: readonly AcpmuxSessionEntry[]) => void,
  fields: Record<string, unknown> = BUSY,
): number {
  const small = readsForOneChange(200, project(), fields);
  const large = readsForOneChange(20_000, project(), fields);
  return large / Math.max(1, small);
}

test("the hover cards read only the changed session", () => {
  expect(
    growth(() => {
      const store = new SessionHoverStore();
      return (sessions) => store.set(sessions);
    }),
  ).toBeLessThan(2);
});

test("the sub-session store and its name index read only the changed session", () => {
  expect(
    growth(() => {
      const store = new SubsessionStore();
      return (sessions) => store.set(sessions);
    }),
  ).toBeLessThan(2);
});

test("the folder lists keep their input while no folder, place or activity changed", () => {
  let runs = 0;
  const project = () => {
    const by = new SessionsBy(folderFields);
    let input: readonly AcpmuxSessionEntry[] | undefined;
    return (sessions: readonly AcpmuxSessionEntry[]) => {
      const kept = by.of(sessions);
      // The memo over it (App.tsx newTabProjectList): runs again only when its input moved.
      if (kept !== input) {
        runs++;
        recentLocalFolders(kept);
      }
      input = kept;
    };
  };
  // A rename and an unread mark move no folder: the folder list is not made again.
  expect(growth(project, { title: "Renamed", unread: true })).toBeLessThan(2);
  expect(runs).toBe(2);
});

test("a session added or removed is still seen", () => {
  const by = new SessionsBy(folderFields);
  const one = [counted(1), counted(2)];
  expect(by.of(one)).toBe(one);
  const same = [one[0]!, one[1]!];
  expect(by.of(same)).toBe(one);
  const added = [...one, counted(3)];
  expect(by.of(added)).toBe(added);
  const swapped = [added[0]!, added[1]!, counted(4)];
  expect(by.of(swapped)).toBe(swapped);
  const moved = [counted(9, { cwd: "/Users/me/code/elsewhere" }), swapped[1]!, swapped[2]!];
  expect(by.of(moved)).toBe(moved);
});

test("a page that lists one session twice in place of another drops the one it left out", () => {
  const a = counted(1, { startedBy: "s0" });
  const b = counted(2, { startedBy: "s0" });
  const hover = new SessionHoverStore();
  const subsessions = new SubsessionStore();
  hover.set([a, b]);
  subsessions.set([a, b]);
  // Same length, every id known: only the ids' count shows that s2 left.
  const twice = [a, counted(1, { startedBy: "s0", title: "Again" })];
  hover.set(twice);
  subsessions.set(twice);
  expect(hover.get("s2")).toBeUndefined();
  expect(subsessions.get("s2")).toBeUndefined();
  expect(subsessions.has("s2")).toBe(false);
});

test("a session listed twice in place of another, then back, is in the folder input again", () => {
  const by = new SessionsBy(folderFields);
  const a = () => counted(1);
  const b = () => counted(2, { cwd: "/Users/me/code/b" });
  by.of([b(), a()]);
  by.of([a(), a()]);
  const back = [b(), a()];
  expect(by.of(back)).toBe(back);
});

test("a sender alias freed by a session listed twice resolves to the session left with it", () => {
  const store = new SubsessionStore();
  store.set([counted(1, { name: "old" }), counted(1, { name: "new" }), counted(2, { name: "old" })]);
  store.set([counted(1, { name: "new" }), counted(1, { name: "new" }), counted(2, { name: "old" })]);
  expect(store.find("old")).toBe("s2");
});

test("a session listed twice, then once, drops what only the copy it lost said", () => {
  const store = new SessionHoverStore();
  const peer = counted(1, { host: "far", hostKind: "peer", peer: "far", agentSessionId: "x1" });
  const local = counted(1, { agentSessionId: "x2" });
  store.set([peer, local]);
  store.set([counted(1, { agentSessionId: "x2" })]);
  expect(store.host("s1")).toBeUndefined();
  expect(store.byAgentSession("x1")).toBeUndefined();
});

test("two chats of one agent session, reordered, link to the one now first", () => {
  const store = new SessionHoverStore();
  const a = counted(1, { agentSessionId: "x" });
  const b = counted(2, { agentSessionId: "x" });
  store.set([a, b]);
  store.set([b, a]);
  expect(store.byAgent("claude", "x")).toBe("s2");
  expect(store.byAgentSession("x")).toBe("s2");
});
