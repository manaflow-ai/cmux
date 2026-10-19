// Started session cards (startedSessions.ts, StartedSessionCard.tsx): the chats a chat's agent
// started draw as cards where each was started, with a pull request badge, and their names in a
// reply draw as chips that open them.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { sessionEntry } from "../sessionList";
import { renderInline } from "../conversation/Markdown";
import { StartedSessionCard } from "./StartedSessionCard";
import {
  STARTED_SESSIONS,
  type StartedCache,
  offerChildren,
  sessionMentions,
  splitMentions,
  startedPullRequests,
  startedSessions,
  withStartedSessions,
} from "./startedSessions";

const PARENT = "parent-1";

const child = (sessionId: string, extra: Record<string, unknown> = {}) =>
  sessionEntry({ sessionId, title: `Task ${sessionId}`, spawnedBy: PARENT, createdAt: 100, ...extra });

const row = (id: string, at: number, kind = "assistant"): AcpmuxRow => ({ id, version: 1, at, kind });

describe("startedSessions", () => {
  test("lists the chats the open chat started, oldest first, without archived or offer children", () => {
    const sessions = [
      child("b", { createdAt: 300 }),
      child("a", { createdAt: 200 }),
      child("archived", { tags: ["archived"] }),
      child("offered"),
      sessionEntry({ sessionId: "other", spawnedBy: "someone-else", createdAt: 1 }),
      sessionEntry({ sessionId: PARENT }),
    ];
    const started = startedSessions(sessions, PARENT, { exclude: new Set(["offered"]) });
    expect(started.map((s) => s.sessionId)).toEqual(["a", "b"]);
    expect(startedSessions(sessions, undefined)).toEqual([]);
  });

  test("a running chat shows its latest tool call; an idle one does not", () => {
    const sessions = [child("run", { indicator: "working" }), child("idle", { indicator: "done", unread: true })];
    const started = startedSessions(sessions, PARENT, { activity: { run: "Running ls", idle: "Old call" } });
    expect(started.find((s) => s.sessionId === "run")).toMatchObject({ state: "running", activity: "Running ls" });
    expect(started.find((s) => s.sessionId === "idle")).toMatchObject({ state: "idle", unread: true });
    expect(started.find((s) => s.sessionId === "idle")?.activity).toBeUndefined();
  });
});

describe("startedPullRequests", () => {
  test("counts each pull request once, recorded URL or branch PR, toned by the branch PR", () => {
    const entry = child("c", {
      pullRequests: [
        "https://github.com/o/r/pull/7",
        "https://github.com/o/r/pull/8",
        "https://github.com/O/R/pull/8/",
      ],
      pullRequest: { number: 8, title: "x", state: "open", checks: "passing" },
    });
    expect(startedPullRequests(entry)).toEqual({ count: 2, tone: "ready" });
  });

  test("failing checks, merged, and URL-only badges", () => {
    expect(
      startedPullRequests(child("f", { pullRequest: { number: 1, title: "x", state: "open", checks: "failing" } })),
    ).toEqual({ count: 1, tone: "failing" });
    expect(startedPullRequests(child("m", { pullRequest: { number: 1, title: "x", state: "merged" } }))).toEqual({
      count: 1,
      tone: "merged",
    });
    expect(startedPullRequests(child("u", { pullRequests: ["https://github.com/o/r/pull/3"] }))).toEqual({
      count: 1,
      tone: "unknown",
    });
    expect(startedPullRequests(child("none"))).toBeUndefined();
  });
});

describe("withStartedSessions", () => {
  const started = (id: string, createdAt?: number) => ({
    sessionId: id,
    title: `Task ${id}`,
    state: "idle" as const,
    ...(createdAt !== undefined ? { createdAt } : {}),
  });

  test("places a card before the first row made after the chat, inside its turn", () => {
    const rows = [row("u1", 10, "user"), row("a1", 20), row("s1", 40, "turnSummary"), row("u2", 50, "user")];
    // Started at 30: after a1, stamped before the summary.
    let out = withStartedSessions(rows, [started("x", 30)]);
    expect(out.map((r) => r.id)).toEqual(["u1", "a1", `${STARTED_SESSIONS}-x`, "s1", "u2"]);
    // Started at 45, after the summary was written but before the next prompt: still that turn's.
    out = withStartedSessions(rows, [started("y", 45)]);
    expect(out.map((r) => r.id)).toEqual(["u1", "a1", `${STARTED_SESSIONS}-y`, "s1", "u2"]);
  });

  test("chats started together share one card row; one without createdAt goes last", () => {
    const rows = [row("u1", 10, "user"), row("a1", 20)];
    const out = withStartedSessions(rows, [started("x", 15), started("y", 16), started("z")]);
    expect(out.map((r) => r.id)).toEqual(["u1", `${STARTED_SESSIONS}-x`, "a1", `${STARTED_SESSIONS}-z`]);
    expect(out[1]!.started!.map((s) => s.sessionId)).toEqual(["x", "y"]);
  });

  test("keeps an unchanged card row's object and bumps the version of a changed one", () => {
    const rows = [row("u1", 10, "user")];
    const cache: StartedCache = new Map();
    const first = withStartedSessions(rows, [started("x", 20)], cache)[1]!;
    expect(withStartedSessions(rows, [started("x", 20)], cache)[1]).toBe(first);
    const changed = withStartedSessions(rows, [{ ...started("x", 20), state: "running" as const }], cache)[1]!;
    expect(changed).not.toBe(first);
    expect(changed.version).toBe(first.version + 1);
  });

  test("returns the rows as they are with no started chats", () => {
    const rows = [row("u1", 10, "user")];
    expect(withStartedSessions(rows, [])).toBe(rows);
  });
});

describe("offerChildren", () => {
  test("names the chats an offer started", () => {
    const offer: AcpmuxRow = {
      ...row("o", 1, "sessionOffer"),
      offers: [
        { offerId: "1", title: "t", prompt: "p", childSessionId: "kid" },
        { offerId: "2", title: "t", prompt: "p" },
      ] as AcpmuxRow["offers"],
    };
    expect([...offerChildren([offer])]).toEqual(["kid"]);
  });
});

describe("name chips", () => {
  const children = [
    { sessionId: "sess-1", title: "Triage the failing tests", state: "running" as const },
    { sessionId: "sess-2", title: "Fix", state: "idle" as const },
  ];

  test("a long title and a session id are mentions; a short title is not", () => {
    const texts = sessionMentions(children).map((m) => m.text);
    expect(texts).toContain("Triage the failing tests");
    expect(texts).toContain("sess-1");
    expect(texts).toContain("sess-2");
    expect(texts).not.toContain("Fix");
  });

  test("splits prose at whole mentions only", () => {
    const mentions = sessionMentions(children);
    const pieces = splitMentions("Both run: Triage the failing tests and sess-2; not sess-22.", mentions);
    expect(pieces.map((p) => (typeof p === "string" ? p : `[${p.mention.sessionId}]`))).toEqual([
      "Both run: ",
      "[sess-1]",
      " and ",
      "[sess-2]",
      "; not sess-22.",
    ]);
    expect(splitMentions("nothing here", mentions)).toEqual(["nothing here"]);
  });

  test("a reply draws a started chat's name, code span and session link as chips", () => {
    const opened: string[] = [];
    const started = { mentions: sessionMentions(children), open: (id: string) => opened.push(id) };
    const html = renderToStaticMarkup(
      <>{renderInline("Running: Triage the failing tests, `sess-2` and [it](cmux://session/sess-1).", { started })}</>,
    );
    expect(html.match(/acpmux-started-chip/g)?.length).toBe(3);
    expect(html).toContain(">Triage the failing tests</button>");
    expect(html).toContain(">sess-2</button>");
    expect(html).toContain(">it</button>");
    // Without started chats a reply draws as before.
    expect(renderToStaticMarkup(<>{renderInline("Triage the failing tests")}</>)).not.toContain("acpmux-started");
  });
});

describe("StartedSessionCard", () => {
  test("draws the title, what the chat does now, its pull request badge and state", () => {
    const html = renderToStaticMarkup(
      <StartedSessionCard
        child={{
          sessionId: "s",
          title: "Switch gh-merge-green to merge-freeze issues",
          state: "running",
          activity: "`ss -ltnp`",
          pullRequests: { count: 2, tone: "ready" },
        }}
        onOpen={() => undefined}
      />,
    );
    expect(html).toContain("Switch gh-merge-green to merge-freeze issues");
    expect(html).toContain(">ss -ltnp<");
    expect(html).toContain('data-state="running"');
    expect(html).toContain('data-tone="ready"');
    expect(html).toContain("2 Ready");
  });

  test("an idle chat has no second line", () => {
    const html = renderToStaticMarkup(
      <StartedSessionCard child={{ sessionId: "s", title: "Done task", state: "idle" }} onOpen={() => undefined} />,
    );
    expect(html).not.toContain("acpmux-started-line");
  });
});
