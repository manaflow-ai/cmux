import { describe, expect, test } from "bun:test";
import {
  filterSessions,
  shortAge,
  groupMark,
  GROUP_ROWS,
  groupByProject,
  homePath,
  projectLabel,
  sessionEntry,
  sessionMark,
  sessionPlace,
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
  test("a generated name without a prompt yet is a new chat, never the launch profile's name", () => {
    expect(sessionTitle({ sessionId: "s1", name: "claude-2", harness: "claude" })).toBe("New chat");
    expect(sessionTitle({ sessionId: "s1", name: "claude-sr", harness: "claude-sr", family: "claude" })).toBe(
      "New chat",
    );
    expect(sessionTitle({ sessionId: "s1", name: "claude-sr-2", harness: "claude-sr" })).toBe("New chat");
    expect(sessionTitle({ sessionId: "abcdef123456" })).toBe("New chat");
  });
  test("a generated name falls back to the last prompt, and a fork's name is generated too", () => {
    expect(sessionTitle({ sessionId: "s1", name: "claude-sr-1", harness: "claude-sr", lastPrompt: "Ship it" })).toBe(
      "Ship it",
    );
    expect(sessionTitle({ sessionId: "s1", name: "codex-fork-1", harness: "codex", title: "Fix the login flow" })).toBe(
      "Fix the login flow",
    );
  });
});

describe("project labels", () => {
  test("the folder's last component", () => expect(projectLabel("/Users/dev/src/cmux/")).toBe("cmux"));
  test("a home folder is ~", () => {
    expect(projectLabel("/Users/lee")).toBe("~");
    expect(projectLabel("/home/lee")).toBe("~");
    expect(homePath("/Users/lee/code/app")).toBe("~/code/app");
    expect(homePath("/home/lee")).toBe("~");
    expect(homePath("/Users/lee/")).toBe("~/");
    expect(homePath("/opt/Users/lee/app")).toBe("/opt/Users/lee/app");
    expect(homePath("/Users")).toBe("/Users");
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
        preview: "Last reply",
        queue: ["dropped"],
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
      preview: "Last reply",
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

  test("keep where a session runs and its pull request, and drop malformed ones", () => {
    const entry = sessionEntry({
      sessionId: "s",
      host: "hearty-beige-elk",
      hostKind: "cloud",
      branch: "fix",
      worktree: "~/w/fix",
      pinned: true,
      pullRequest: { number: 12, title: "Fix", state: "open", reviewReady: true },
    });
    expect(entry).toMatchObject({
      host: "hearty-beige-elk",
      hostKind: "cloud",
      branch: "fix",
      worktree: "~/w/fix",
      pinned: true,
      pullRequest: { number: 12, title: "Fix", state: "open", reviewReady: true },
    });
    const odd = sessionEntry({ sessionId: "s", host: "", hostKind: "mars", pullRequest: { title: "no number" } });
    expect([odd.host, odd.hostKind, odd.pullRequest]).toEqual([undefined, undefined, undefined]);
    // A closed pull request is kept as closed; an unknown state or a bad number drops it.
    expect(
      sessionEntry({ sessionId: "s", pullRequest: { number: 3, title: "Old", state: "closed" } }).pullRequest?.state,
    ).toBe("closed");
    // CI checks ride along only as a known rollup.
    const checks = (value: unknown) =>
      sessionEntry({ sessionId: "s", pullRequest: { number: 3, title: "T", state: "open", checks: value } }).pullRequest
        ?.checks;
    expect([checks("failing"), checks("green"), checks(undefined)]).toEqual(["failing", undefined, undefined]);
    for (const pullRequest of [
      { number: 3, title: "T", state: "weird" },
      { number: Number.NaN, title: "T", state: "open" },
      { number: 1.5, title: "T", state: "open" },
      { number: 3, title: "", state: "open" },
    ])
      expect(sessionEntry({ sessionId: "s", pullRequest }).pullRequest).toBeUndefined();
  });
});

describe("sections", () => {
  test("pinned sessions leave their project, and one folder on two machines is one project", () => {
    const { pinned, groups } = sidebarSections([
      { sessionId: "a", cwd: "/src/acpmux", host: "This Mac", hostKind: "local", updatedAt: 5 },
      { sessionId: "b", cwd: "/src/acpmux", host: "cobalt-butte", hostKind: "cloud", updatedAt: 4 },
      { sessionId: "e", cwd: "/src/cloud", host: "cobalt-butte", hostKind: "cloud", updatedAt: 2 },
      { sessionId: "f", cwd: "/src/cloud/", host: "cobalt-butte", hostKind: "cloud", updatedAt: 1 },
      { sessionId: "c", cwd: "/src/acpmux", pinned: true, updatedAt: 3 },
      { sessionId: "d", cwd: "/src/web", pinned: true, updatedAt: 9 },
    ]);
    expect(pinned.map((session) => session.sessionId)).toEqual(["d", "c"]);
    expect(
      groups.map((group) => [group.label, group.host, group.sessions.map((session) => session.sessionId)]),
    ).toEqual([
      ["acpmux", undefined, ["a", "b"]],
      ["cloud", "cobalt-butte", ["e", "f"]],
    ]);
  });
  test("a cloud-only folder is one project per machine, and a bare host counts as remote", () => {
    const groups = groupByProject([
      { sessionId: "a", cwd: "/workspace", host: "elk", hostKind: "cloud", updatedAt: 3 },
      { sessionId: "b", cwd: "/workspace", host: "butte", updatedAt: 2 },
      { sessionId: "c", cwd: "/src/web", host: "elk", hostKind: "cloud", updatedAt: 1 },
      { sessionId: "d", cwd: "/src/web", host: "butte", hostKind: "cloud", updatedAt: 0 },
      { sessionId: "e", cwd: "/src/web", hostKind: "local", updatedAt: -1 },
    ]);
    expect(
      groups.map((group) => [group.label, group.host, group.sessions.map((session) => session.sessionId)]),
    ).toEqual([
      ["workspace", "elk", ["a"]],
      ["workspace", "butte", ["b"]],
      ["web", undefined, ["c", "d", "e"]],
    ]);
  });

  test("a row's place: the cloud machine with its branch, a worktree's folder, a branch, never this Mac", () => {
    expect(sessionPlace({ sessionId: "a", host: "elk", hostKind: "cloud", branch: "ci" })).toEqual({
      kind: "cloud",
      label: "elk",
      branch: "ci",
    });
    expect(sessionPlace({ sessionId: "a", host: "elk", hostKind: "cloud", branch: "ci" }, "elk")).toEqual({
      kind: "branch",
      label: "ci",
    });
    expect(sessionPlace({ sessionId: "b", worktree: "~/code/web-worktrees/home/" })).toEqual({
      kind: "worktree",
      label: "home",
    });
    expect(sessionPlace({ sessionId: "c", host: "This Mac", hostKind: "local" })).toBeUndefined();
  });
  test("pinning the local session at a folder keeps its cloud sessions in one project", () => {
    const { groups } = sidebarSections([
      { sessionId: "l", cwd: "/src/web", hostKind: "local", pinned: true, updatedAt: 3 },
      { sessionId: "e", cwd: "/src/web/", host: "elk", hostKind: "cloud", updatedAt: 2 },
      { sessionId: "b", cwd: "/src/web", host: "butte", hostKind: "cloud", updatedAt: 1 },
    ]);
    expect(
      groups.map((group) => [group.label, group.host, group.sessions.map((session) => session.sessionId)]),
    ).toEqual([["web", undefined, ["e", "b"]]]);
  });
  test("a search matches every word in title, folder, branch or cloud machine, and never splits a project", () => {
    const list: AcpmuxSessionEntry[] = [
      { sessionId: "l", displayTitle: "Lint", cwd: "/src/web", hostKind: "local", updatedAt: 3 },
      { sessionId: "e", displayTitle: "Flaky CI", cwd: "/src/web", host: "elk", hostKind: "cloud", updatedAt: 2 },
      {
        sessionId: "b",
        displayTitle: "CI cache",
        cwd: "/src/web",
        host: "butte",
        hostKind: "cloud",
        branch: "ci-keys",
        updatedAt: 1,
      },
      { sessionId: "m", displayTitle: "Notes", cwd: "/src/docs", host: "This Mac", hostKind: "local", updatedAt: 0 },
    ];
    const ids = (query: string) => filterSessions(list, query).map((session) => session.sessionId);
    expect(ids("ci")).toEqual(["e", "b"]);
    expect(ids("CI  KEYS")).toEqual(["b"]);
    expect(ids("elk")).toEqual(["e"]);
    expect(ids("this mac")).toEqual([]);
    expect(ids("src")).toEqual([]);
    expect(ids("docs")).toEqual(["m"]);
    expect(ids("  ")).toEqual(["l", "e", "b", "m"]);
    // The local session that anchors /src/web is filtered out, but the cloud matches stay in its project.
    expect(sidebarSections(list, "ci").groups.map((group) => [group.label, group.host])).toEqual([["web", undefined]]);
    // A header keeps the machine it shows unsearched: matching only elk's session doesn't name elk.
    expect(sidebarSections(list, "flaky").groups.map((group) => [group.label, group.host])).toEqual([
      ["web", undefined],
    ]);
  });
});

describe("rail helpers", () => {
  test("a project's mark is its most urgent session: needs input over a lost agent", () => {
    const [group] = groupByProject([
      { sessionId: "lost", cwd: "/p", status: "disconnected", updatedAt: 2 },
      { sessionId: "ask", cwd: "/p", status: "waiting", updatedAt: 1 },
    ]);
    expect(groupMark(group)).toBe("input");
    expect(groupMark({ ...group, sessions: group.sessions.slice(0, 1) })).toBe("error");
    expect(groupMark({ ...group, sessions: [{ sessionId: "x", status: "running" }] })).toBeUndefined();
  });

  test("history ages are compact", () => {
    const now = 100 * 86_400_000;
    const ages = [
      now,
      now - 30_000,
      now - 5 * 60_000,
      now - 3 * 3_600_000,
      now - 2 * 86_400_000,
      now - 42 * 86_400_000,
    ];
    expect(ages.map((at) => shortAge(at, now))).toEqual(["now", "now", "5m", "3h", "2d", "6w"]);
    expect(shortAge(undefined, now)).toBe("");
  });
});

describe("archived chats", () => {
  test("read acpmux's tag object as well as a tag list", () => {
    expect(sessionEntry({ sessionId: "s", tags: { pinned: "1" } }).pinned).toBe(true);
    expect(sessionEntry({ sessionId: "s", tags: { archived: "1700000000000" } }).archived).toBe(true);
    expect(sessionEntry({ sessionId: "s", tags: ["archived"] }).archived).toBe(true);
    expect(sessionEntry({ sessionId: "s", tags: { work: "1" } })).toMatchObject({ pinned: false, archived: false });
  });

  test("leave the sidebar, pinned or not", () => {
    const { pinned, groups } = sidebarSections([
      entry("kept", "/p", 3),
      entry("gone", "/p", 2, { archived: true }),
      entry("gone-pinned", "/p", 1, { archived: true, pinned: true }),
    ]);
    expect(pinned).toEqual([]);
    expect(groups.flatMap((group) => group.sessions.map((session) => session.sessionId))).toEqual(["kept"]);
  });
});

describe("side chats", () => {
  test("a fork tagged side stays beside its chat and off the lists", () => {
    expect(sessionEntry({ sessionId: "f", tags: { side: "s" } }).side).toBe(true);
    const { pinned, groups } = sidebarSections([entry("kept", "/p", 2), entry("aside", "/p", 1, { side: true })]);
    expect(pinned).toEqual([]);
    expect(groups.flatMap((group) => group.sessions.map((session) => session.sessionId))).toEqual(["kept"]);
  });
});
