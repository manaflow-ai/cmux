// Started session cards (startedSessions.ts, StartedSessionCard.tsx): the chats a turn's agent
// started draw as one card of rows at the end of that turn, after its reply, each row the chat's
// title over its status (Claude Code's Changes card), and their names in a reply draw as chips
// that open them.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { sessionEntry } from "../sessionList";
import { renderInline } from "../conversation/Markdown";
import { turnView } from "../conversation/turns";
import { StartedSessionCards } from "./StartedSessionCard";
import { AgentMark } from "../../shared/AgentMark";
import { rowIconSize } from "../icons/iconSize";
import { agentTone } from "../subagents/agentTones";
import {
  STARTED_SESSIONS,
  type StartedSession,
  type StartedCache,
  offerChildren,
  sessionMentions,
  splitMentions,
  startedCardsShown,
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

  test("a running chat is running and an unread one unread; no tool call stands in for what it does", () => {
    const sessions = [child("run", { indicator: "working" }), child("idle", { indicator: "done", unread: true })];
    const started = startedSessions(sessions, PARENT);
    expect(started.find((s) => s.sessionId === "run")).toEqual(expect.objectContaining({ state: "running" }));
    expect(started.find((s) => s.sessionId === "run")).not.toHaveProperty("activity");
    expect(started.find((s) => s.sessionId === "idle")).toMatchObject({ state: "idle", unread: true });
  });
});

describe("startedPullRequests", () => {
  test("counts each pull request once, recorded URL or branch PR, toned and named by the branch PR", () => {
    const entry = child("c", {
      pullRequests: [
        "https://github.com/o/r/pull/7",
        "https://github.com/o/r/pull/8",
        "https://github.com/O/R/pull/8/",
      ],
      pullRequest: { number: 8, title: "x", state: "open", checks: "passing" },
    });
    expect(startedPullRequests(entry)).toEqual({ count: 2, tone: "ready", number: 8, repo: "r" });
  });

  test("failing checks, merged, and URL-only badges", () => {
    expect(
      startedPullRequests(child("f", { pullRequest: { number: 1, title: "x", state: "open", checks: "failing" } })),
    ).toEqual({ count: 1, tone: "failing", number: 1 });
    expect(startedPullRequests(child("m", { pullRequest: { number: 1, title: "x", state: "merged" } }))).toEqual({
      count: 1,
      tone: "merged",
      number: 1,
    });
    // Without a branch PR the newest recorded URL names the badge.
    expect(
      startedPullRequests(
        child("u", { pullRequests: ["https://github.com/o/r/pull/3", "https://github.com/o/cmux/pull/22092"] }),
      ),
    ).toEqual({ count: 2, tone: "unknown", number: 22092, repo: "cmux" });
    expect(startedPullRequests(child("none"))).toBeUndefined();
  });

  test("a branch PR whose number more than one recorded repository has names no repository", () => {
    const entry = child("two", {
      pullRequests: ["https://github.com/o/alpha/pull/7", "https://github.com/o/beta/pull/7"],
      pullRequest: { number: 7, title: "x", state: "open" },
    });
    expect(startedPullRequests(entry)).toEqual({ count: 2, tone: "open", number: 7 });
  });
});

describe("withStartedSessions", () => {
  const started = (id: string, createdAt?: number) => ({
    sessionId: id,
    title: `Task ${id}`,
    state: "idle" as const,
    ...(createdAt !== undefined ? { createdAt } : {}),
  });

  test("places a turn's card after its reply, before its summary, whenever in the turn a chat started", () => {
    const rows = [
      row("u1", 10, "user"),
      row("a1", 20),
      row("a1b", 30),
      row("s1", 40, "turnSummary"),
      row("u2", 50, "user"),
      row("a2", 60),
    ];
    // Started at 15, before the reply was written: still drawn after it, in reading order.
    let out = withStartedSessions(rows, [started("x", 15)]);
    expect(out.map((r) => r.id)).toEqual(["u1", "a1", "a1b", `${STARTED_SESSIONS}-x`, "s1", "u2", "a2"]);
    // Started at 45, after the summary was written but before the next prompt: still that turn's.
    out = withStartedSessions(rows, [started("y", 45)]);
    expect(out.map((r) => r.id)).toEqual(["u1", "a1", "a1b", `${STARTED_SESSIONS}-y`, "s1", "u2", "a2"]);
    // The second turn has no summary yet (it runs): its card goes last.
    out = withStartedSessions(rows, [started("x", 15), started("z", 55)]);
    expect(out.map((r) => r.id)).toEqual([
      "u1",
      "a1",
      "a1b",
      `${STARTED_SESSIONS}-x`,
      "s1",
      "u2",
      "a2",
      `${STARTED_SESSIONS}-z`,
    ]);
  });

  test("a turn's chats share one card; one without createdAt goes in the last turn's", () => {
    const rows = [row("u1", 10, "user"), row("a1", 20)];
    const out = withStartedSessions(rows, [started("x", 15), started("y", 16), started("z")]);
    expect(out.map((r) => r.id)).toEqual(["u1", "a1", `${STARTED_SESSIONS}-x`]);
    expect(out[2]!.started!.map((s) => s.sessionId)).toEqual(["x", "y", "z"]);
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

  test("drops the cached cards of chats no longer shown", () => {
    const cache: StartedCache = new Map();
    withStartedSessions([row("u1", 10, "user")], [started("x", 20)], cache);
    withStartedSessions([row("u1", 10, "user")], [started("y", 20)], cache);
    expect([...cache.keys()]).toEqual([`${STARTED_SESSIONS}-y`]);
  });

  test("a card no row follows yet leaves the running turn's latest step live", () => {
    const activity: AcpmuxRow = { ...row("act", 20, "activity"), items: [] };
    const rows = withStartedSessions([row("u1", 10, "user"), activity], [started("x", 30)]);
    const shown = turnView(rows, new Set(), { working: true });
    expect(shown.find((r) => r.id === "act")?.live).toBe(true);
    expect(shown.at(-1)?.kind).toBe(STARTED_SESSIONS);
  });

  test("a running turn with only its card so far draws the thinking line and the card", () => {
    const rows = withStartedSessions([row("u1", 10, "user")], [started("x", 20)]);
    const shown = turnView(rows, new Set(), { working: true });
    expect(shown.map((r) => r.kind).filter((kind) => kind !== "date")).toEqual(["user", "thinking", STARTED_SESSIONS]);
  });

  test("with Codex runs, a card after the running call leaves that call the live line's", () => {
    const activity: AcpmuxRow = {
      ...row("act", 20, "activity"),
      items: [{ kind: "tool", text: "", tool: { id: "t", title: "bun test", kind: "execute", status: "in_progress" } }],
    };
    const rows = withStartedSessions([row("u1", 10, "user"), activity], [started("x", 30)]);
    const shown = turnView(rows, new Set(), { working: true, liveRuns: true });
    expect(shown.find((r) => r.id === "act")).toBeUndefined();
    expect(shown.find((r) => r.kind === "working")?.doing).toBe("bun test");
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
    { sessionId: "sess-1", title: "Triage the failing tests", state: "running" as const, named: true },
    { sessionId: "sess-2", title: "Fix", state: "idle" as const, named: true },
  ];

  test("a long title and a session id are mentions; a short title is not", () => {
    const texts = sessionMentions(children).map((m) => m.text);
    expect(texts).toContain("Triage the failing tests");
    expect(texts).toContain("sess-1");
    expect(texts).toContain("sess-2");
    expect(texts).not.toContain("Fix");
  });

  test("a title two chats share stays text; their session ids still name each", () => {
    const twins = [
      { sessionId: "twin-1", title: "Triage the failing tests", state: "running" as const, named: true },
      { sessionId: "twin-2", title: "Triage the failing tests", state: "idle" as const, named: true },
    ];
    const mentions = sessionMentions(twins);
    expect(mentions.map((m) => m.text).sort()).toEqual(["twin-1", "twin-2"]);
    expect(splitMentions("Triage the failing tests", mentions)).toEqual(["Triage the failing tests"]);
    const html = renderToStaticMarkup(
      <>{renderInline("`Triage the failing tests` and twin-2", { started: { mentions, open: () => undefined } })}</>,
    );
    expect(html.match(/acpmux-started-chip/g)?.length).toBe(1);
    expect(html).toContain('>twin-2<svg class="acpmux-started-cue"');
  });

  test("a title standing in for a missing one (first prompt, New chat) is never a mention", () => {
    const [untitled] = startedSessions(
      [child("u", { title: undefined, lastPrompt: "Look into the flaky test" })],
      PARENT,
    );
    expect(untitled).toMatchObject({ title: "Look into the flaky test" });
    expect(untitled!.named).toBeUndefined();
    expect(sessionMentions([untitled!]).map((m) => m.text)).toEqual(["u"]);
    const [titled] = startedSessions([child("t")], PARENT);
    expect(titled!.named).toBe(true);
  });

  test("a session id inside a URL or path stays text", () => {
    const mentions = sessionMentions(children);
    for (const text of [
      "see https://host/sessions/sess-1/log",
      "cmux://session/sess-1",
      "~/.acpmux/sessions/sess-1/events.jsonl",
      "sess-1.jsonl",
    ])
      expect(splitMentions(text, mentions)).toEqual([text]);
    // A sentence may still end on one.
    expect(splitMentions("Started sess-1.", mentions).length).toBe(3);
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
    expect(html).toContain('>Triage the failing tests<svg class="acpmux-started-cue"');
    expect(html).toContain('>sess-2<svg class="acpmux-started-cue"');
    expect(html).toContain('>it<svg class="acpmux-started-cue"');
    // Without started chats a reply draws as before.
    expect(renderToStaticMarkup(<>{renderInline("Triage the failing tests")}</>)).not.toContain("acpmux-started");
  });
});

describe("StartedSessionCards", () => {
  const draw = (...started: StartedSession[]) =>
    renderToStaticMarkup(<StartedSessionCards started={started} onOpen={() => undefined} />);

  // Claude Code's Changes card: one container of compact rows, each the title over a status line
  // that starts with the status (glyph and word in its colour), then `· repo #N`; one chevron.
  test("one card of rows, each the title over `Status · repo #N`, with one trailing chevron", () => {
    const html = draw(
      { sessionId: "a", title: "Triage the failing tests", state: "idle" },
      {
        sessionId: "b",
        title: "Switch gh-merge-green to merge-freeze issues",
        state: "running",
        pullRequests: { count: 2, tone: "failing", number: 22092, repo: "cmux" },
      },
    );
    expect(html.match(/class="acpmux-started"/g)?.length).toBe(1);
    expect(html.match(/class="acpmux-started-row"/g)?.length).toBe(2);
    expect(html.match(/acpmux-started-chevron/g)?.length).toBe(2);
    expect(html).not.toContain("acpmux-started-dot");
    expect(html).toMatch(
      /class="acpmux-session-status" data-status="failing"[^]*>Checks failed<[^]*>cmux #22092<[^]*>and 1 more</,
    );
  });

  // Each row says which agent runs it, as Session Info's child chat rows do (ChildSessionRows.tsx):
  // its harness's mark, else the chat icon in a tone stable for its id, before the title.
  test("a row leads with its harness's mark, else its chat icon in its own stable tone", () => {
    const mark = renderToStaticMarkup(<AgentMark agent="codex" size={rowIconSize(12)} />);
    const html = draw(
      { sessionId: "a", title: "Codex task", state: "idle", harness: "codex" },
      { sessionId: "b", title: "Plain task", state: "idle" },
    );
    const [codex, plain] = html.split('class="acpmux-started-row"').slice(1);
    expect(codex).toContain(`<span class="acpmux-started-icon" aria-hidden="true">${mark}`);
    expect(codex!.indexOf("acpmux-started-icon")).toBeLessThan(codex!.indexOf("Codex task"));
    expect(plain).toContain(`class="acpmux-toned-icon" data-agent-tone="${agentTone("b")}"`);
    expect(draw({ sessionId: "b", title: "Plain task", state: "running" })).toContain(
      `data-agent-tone="${agentTone("b")}"`,
    );
  });

  test("an idle chat with nothing to say is one line; a read one with a PR names it", () => {
    expect(draw({ sessionId: "s", title: "Done task", state: "idle" })).not.toContain("acpmux-session-status-line");
    const merged = draw({
      sessionId: "s",
      title: "Done task",
      state: "idle",
      pullRequests: { count: 1, tone: "merged", number: 4 },
    });
    expect(merged).toMatch(/data-status="merged"[^]*>Merged<[^]*>#4</);
    expect(merged).not.toContain("more");
  });

  test("needs input and failed come before the PR; running and new activity say so without one", () => {
    const failed = draw({
      sessionId: "s",
      title: "Broken task",
      state: "failed",
      pullRequests: { count: 1, tone: "failing", number: 9, repo: "cmux" },
    });
    expect(failed).toMatch(/data-status="failed"[^]*>Failed<[^]*>cmux #9</);
    expect(failed).not.toContain("Checks failed");
    expect(draw({ sessionId: "s", title: "Asking task", state: "waiting" })).toMatch(
      /data-status="waiting"[^]*>Needs input</,
    );
    expect(draw({ sessionId: "s", title: "Busy task", state: "running" })).toMatch(
      /data-status="running"[^]*>Running</,
    );
    expect(draw({ sessionId: "s", title: "Fresh task", state: "idle", unread: true })).toMatch(
      /data-status="unread"[^]*>New activity</,
    );
  });

  test("a pull request of unknown state names no status, only `#N`", () => {
    const html = draw({
      sessionId: "s",
      title: "URL task",
      state: "idle",
      pullRequests: { count: 1, tone: "unknown", number: 3 },
    });
    expect(html).toContain(">#3<");
    expect(html).not.toContain('acpmux-session-status"');
  });

  test("started session cards are off by default", () => {
    expect(startedCardsShown()).toBe(false);
  });
});
