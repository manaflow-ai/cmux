import { describe, expect, test } from "bun:test";
import {
  GROUP_ROWS,
  groupByProject,
  projectLabel,
  sessionEntry,
  sessionMark,
  sessionTitle,
  sidebarSections,
  visibleSessions,
  type AcpmuxSessionEntry,
} from "./sessionList";

const entry = (
  sessionId: string,
  cwd: string,
  updatedAt: number,
  extra: Partial<AcpmuxSessionEntry> = {},
): AcpmuxSessionEntry => ({ sessionId, cwd, updatedAt, displayTitle: sessionId, ...extra });

describe("session titles", () => {
  test("a generated name shows the first prompt", () => {
    expect(sessionTitle({ sessionId: "s1", name: "codex", harness: "codex", title: "Fix the login flow" })).toBe(
      "Fix the login flow",
    );
    expect(sessionTitle({ sessionId: "s1", name: "codex-3", harness: "codex", title: "Fix the login flow" })).toBe(
      "Fix the login flow",
    );
  });
  test("a name the user gave wins over the prompt", () => {
    expect(sessionTitle({ sessionId: "s1", name: "login-fix", harness: "codex", title: "Fix the login flow" })).toBe(
      "login-fix",
    );
    expect(sessionTitle({ sessionId: "s1", name: "codex-2b", harness: "codex", title: "Fix the login flow" })).toBe(
      "codex-2b",
    );
    expect(sessionTitle({ sessionId: "s1", name: "codex-", harness: "codex", title: "Fix the login flow" })).toBe(
      "codex-",
    );
  });
  test("a generated name without a prompt yet shows the name, then the id", () => {
    expect(sessionTitle({ sessionId: "s1", name: "claude-2", harness: "claude" })).toBe("claude-2");
    expect(sessionTitle({ sessionId: "abcdef123456" })).toBe("abcdef12");
  });
});

describe("project labels", () => {
  test("the folder's last component", () => expect(projectLabel("/Users/lee/src/cmux/")).toBe("cmux"));
  test("a home folder is ~", () => {
    expect(projectLabel("/Users/lee")).toBe("~");
    expect(projectLabel("/home/lee")).toBe("~");
  });
  test("no folder", () => expect(projectLabel(undefined)).toBe("No folder"));
});

describe("grouping", () => {
  test("one header per folder, groups and rows newest first", () => {
    const groups = groupByProject([
      entry("a1", "/src/app", 10),
      entry("b1", "/src/web/", 30),
      entry("a2", "/src/app", 20),
      entry("c1", "", 5),
    ]);
    expect(groups.map((group) => group.label)).toEqual(["web", "app", "No folder"]);
    expect(groups[1].sessions.map((session) => session.sessionId)).toEqual(["a2", "a1"]);
    expect(groups[0].cwd).toBe("/src/web");
  });

  test("a long group shows its first rows unless expanded or holding the selection", () => {
    const sessions = Array.from({ length: GROUP_ROWS + 4 }, (_, index) => entry(`s${index}`, "/p", 100 - index));
    const [group] = groupByProject(sessions);
    expect(visibleSessions(group, false)).toEqual({ rows: sessions.slice(0, GROUP_ROWS), hidden: 4 });
    expect(visibleSessions(group, true).hidden).toBe(0);
    expect(visibleSessions(group, false, `s${GROUP_ROWS + 2}`).hidden).toBe(0);
    // One extra row is shown rather than a "Show 1 more".
    const [short] = groupByProject(sessions.slice(0, GROUP_ROWS + 1));
    expect(visibleSessions(short, false).hidden).toBe(0);
  });
});

describe("row marks", () => {
  test("a pending permission or a wait for one needs input before anything else", () => {
    expect(sessionMark(entry("s", "/p", 1, { status: "running", pendingPermissions: 1 }), false)).toBe("input");
    expect(sessionMark(entry("s", "/p", 1, { status: "waiting" }), true)).toBe("input");
  });
  test("running, lost, and unseen work", () => {
    expect(sessionMark(entry("s", "/p", 1, { status: "running", unread: true }), false)).toBe("running");
    expect(sessionMark(entry("s", "/p", 1, { status: "disconnected" }), false)).toBe("error");
    expect(sessionMark(entry("s", "/p", 1, { status: "idle", unread: true }), false)).toBe("unread");
    expect(sessionMark(entry("s", "/p", 1, { status: "idle", unread: true }), true)).toBeUndefined();
  });
});

describe("summary entries", () => {
  test("keep the fields the sidebar needs from acpmux's summary", () => {
    expect(
      sessionEntry({
        sessionId: "s",
        name: "codex",
        harness: "codex",
        title: "Hi",
        cwd: "/p",
        updatedAt: 7,
        status: "waiting",
        pendingPermissions: 2,
        unread: true,
        preview: "dropped",
      }),
    ).toEqual({
      sessionId: "s",
      displayTitle: "Hi",
      title: "Hi",
      name: "codex",
      harness: "codex",
      status: "waiting",
      model: undefined,
      cwd: "/p",
      updatedAt: 7,
      pendingPermissions: 2,
      unread: true,
      pinned: false,
      host: undefined,
    });
  });
  test("read the pinned tag and the host", () => {
    const entry = sessionEntry({ sessionId: "s", tags: ["work", "pinned"], host: "cobalt-butte" });
    expect([entry.pinned, entry.host]).toEqual([true, "cobalt-butte"]);
    expect(sessionEntry({ sessionId: "s", tags: "pinned", host: "" })).toMatchObject({
      pinned: false,
      host: undefined,
    });
  });
});

describe("sections", () => {
  test("pinned sessions leave their project, and one folder on two machines is two projects", () => {
    const { pinned, groups } = sidebarSections([
      { sessionId: "a", cwd: "/src/acpmux", updatedAt: 5 },
      { sessionId: "b", cwd: "/src/acpmux", host: "cobalt-butte", updatedAt: 4 },
      { sessionId: "c", cwd: "/src/acpmux", pinned: true, updatedAt: 3 },
      { sessionId: "d", cwd: "/src/web", pinned: true, updatedAt: 9 },
    ]);
    expect(pinned.map((session) => session.sessionId)).toEqual(["d", "c"]);
    expect(
      groups.map((group) => [group.label, group.host, group.sessions.map((session) => session.sessionId)]),
    ).toEqual([
      ["acpmux", undefined, ["a"]],
      ["acpmux", "cobalt-butte", ["b"]],
    ]);
  });
});
