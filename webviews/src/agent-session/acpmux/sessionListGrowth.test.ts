// l10n-allow-file: test fixtures.
// One session's change costs the same at any list size (Leo, 2026-11-04: "never ... acceptable ...
// linear time growth degradation"): the pane's per-snapshot projections of the session list read
// the changed session, not every listed one. Counted, not timed, so a busy runner cannot fail it:
// each listed entry counts the reads of its fields other than its id (an id lookup per entry is how
// a projection finds what changed), and one change at 20,000 sessions must read about what it reads
// at 200. bench/update-one.bench.ts times the same paths in the real pane.
import { expect, test } from "bun:test";
import { homeLists } from "./homeListsModel";
import { workedProfiles } from "./modelCatalogData";
import { pillAsks } from "./needsYou/jumpPillModel";
import { needsYouItems } from "./needsYou/model";
import { promptSuggestion } from "./promptSuggestion";
import { hatQuestions } from "./question/hatModel";
import { noteReplaced, SessionIndex, sessionIndex, type SessionMark } from "./sessionIndex";
import { folderFields, recentLocalFolders, sessionEntry, SessionsBy, type AcpmuxSessionEntry } from "./sessionList";
import { SessionHoverStore } from "./started/sessionHover";
import { SubsessionStore } from "./subagents/subsessions";

let reads = 0;
/// The first entries of any list hold what the home lists show: a few chats waiting on the person, a
/// few open pull requests (one ready for review) and a few working, the same at every size, as
/// bench/update-one.bench.ts lists them. Only the list's length grows.
const shows = (index: number): Record<string, unknown> =>
  index >= 150
    ? {}
    : {
        ...(index % 50 === 7 ? { status: "waiting", indicator: "input" } : {}),
        ...(index % 50 === 9
          ? { pullRequest: { number: index, title: `PR ${index}`, state: "open", reviewReady: true } }
          : {}),
        ...(index % 50 === 11 ? { pullRequest: { number: index, title: `PR ${index}`, state: "draft" } } : {}),
        ...(index % 50 === 13 ? { indicator: "working" } : {}),
      };
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
    ...shows(index),
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

test("Waiting on you reads only the changed session", () => {
  expect(growth(() => (sessions) => needsYouItems({ sessions, asks: [] }))).toBeLessThan(2);
});

test("a new chat's home lists read only the changed session", () => {
  expect(growth(() => (sessions) => homeLists(sessions as AcpmuxSessionEntry[], "s1"))).toBeLessThan(2);
});

test("the composer's suggested pull request reads only the changed session", () => {
  const here = { sessionId: "s1", cwd: "/Users/me/code/p9" };
  expect(growth(() => (sessions) => promptSuggestion(sessions, here, 2_000_000))).toBeLessThan(2);
});

test("the pill and the hat read only the changed session", () => {
  expect(
    growth(() => (sessions) => {
      pillAsks(needsYouItems({ sessions, asks: [] }), sessions, "s2");
      hatQuestions({ sessionId: "s2", rows: [], sessions, asks: [] });
    }),
  ).toBeLessThan(2);
});

test("an index made from the last one in place matches one made whole", () => {
  const marks: SessionMark[] = ["waiting", "openPullRequest", "working", "started"];
  const same = (list: readonly AcpmuxSessionEntry[]) => {
    const whole = SessionIndex.build(list);
    const made = sessionIndex(list);
    for (const mark of marks) expect(made.of(mark)).toEqual(whole.of(mark));
    for (const entry of list) expect(made.get(entry.sessionId)).toBe(entry);
  };
  let list: readonly AcpmuxSessionEntry[] = Array.from({ length: 300 }, (_, index) => counted(index));
  same(list);
  // A chat starts waiting, one stops, a pull request opens, a dot goes from working to done: through
  // the recorded change (direct.ts) and through a copy compared by identity.
  const changes: [number, Record<string, unknown>][] = [
    [20, { status: "waiting" }],
    [7, { status: "idle" }],
    [250, { pullRequest: { number: 1, title: "PR", state: "open" } }],
    [13, { indicator: "done" }],
  ];
  changes.forEach(([at, fields], step) => {
    const next = list.slice();
    next[at] = counted(at, fields);
    if (step % 2 === 0) noteReplaced(list, next, [at]);
    same(next);
    list = next;
  });
});

test("the folder lists follow a recorded in-place change without walking the list", () => {
  const by = new SessionsBy(folderFields);
  const one = Array.from({ length: 300 }, (_, index) => counted(index));
  expect(by.of(one)).toBe(one);
  const renamed = one.slice();
  renamed[5] = counted(5, { title: "Renamed" });
  noteReplaced(one, renamed, [5]);
  reads = 0;
  expect(by.of(renamed)).toBe(one);
  expect(reads).toBeLessThan(20);
  const moved = renamed.slice();
  moved[6] = counted(6, { cwd: "/Users/me/code/elsewhere" });
  noteReplaced(renamed, moved, [6]);
  expect(by.of(moved)).toBe(moved);
});

test("the picker's worked profiles follow a recorded change at that chat alone, as a whole read orders them", () => {
  const harnesses = ["claude", "codex", "gemini"];
  const worked = (index: number, fields: Record<string, unknown> = {}) =>
    counted(index, { harness: harnesses[index % 3], lastTurn: { status: "completed" }, ...fields });
  let list: readonly AcpmuxSessionEntry[] = Array.from({ length: 3000 }, (_, index) => worked(index));
  expect(workedProfiles(list)).toEqual(["gemini", "codex", "claude"]);
  // Newer; then the newest chat no longer completed, which reads the list again (its profile's
  // next newest is not kept); then a tie that the earlier place wins.
  const changes: [number, Record<string, unknown>, boolean][] = [
    [30, { updatedAt: 9_000_000 }, true],
    [30, { lastTurn: { status: "failed" } }, false],
    [4, { updatedAt: 1_000_000 + 2999 }, true],
  ];
  for (const [at, fields, flat] of changes) {
    const next = list.slice();
    next[at] = worked(at, fields);
    noteReplaced(list, next, [at]);
    reads = 0;
    const made = workedProfiles(next);
    if (flat) expect(reads).toBeLessThan(20);
    expect(made).toEqual(workedProfiles(next.slice()));
    list = next;
  }
  expect(workedProfiles(list)).toEqual(["codex", "gemini", "claude"]);
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
