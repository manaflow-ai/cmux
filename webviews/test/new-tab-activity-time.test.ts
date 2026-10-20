// l10n-allow-file: test fixtures.
// The New Tab's Chats list sorts and labels chats by when the person or the agent last did
// something in them, never by acpmux's `updatedAt`. `updatedAt` moves on every logged record: a
// pane that shows a chat warms or resumes its agent (host_started, initialize, the replayed
// transcript, status ready), the idle pool stops it five minutes later (exited, status idle), a
// draft or a tag is saved. Leo's list (2026-10-19, nightly fc1d07a) swapped two old, idle chats on
// every workspace switch and labelled both "now" while their last turns were an hour or two old.
import { expect, test } from "bun:test";
import { recentChatCards } from "../src/agent-session/acpmux/newtab/screenModel";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";

const MINUTE = 60_000;
const T0 = Math.floor(Date.UTC(2026, 9, 20, 2, 40) / MINUTE) * MINUTE;
const ago = (minutes: number) => T0 - minutes * MINUTE;

/// A daemon session summary as `_acpmux/sessions` sends it, with the fields the lists read.
function summary(
  sessionId: string,
  title: string,
  harness: string,
  lastTurnEnded: number | null,
  updatedAt: number,
  extra: Record<string, unknown> = {},
) {
  return {
    sessionId,
    title,
    name: title,
    harness,
    status: "idle",
    cwd: "/Users/you/src/cmux",
    createdAt: ago(600),
    updatedAt,
    lastPrompt: "hello",
    turnCount: 3,
    queued: 0,
    pendingPermissions: 0,
    inputSince: null,
    lastTurn: lastTurnEnded === null ? null : { endedAt: lastTurnEnded, status: "completed" },
    ...extra,
  };
}

/// The chats as one workspace switch leaves them: `warmed` names the chats whose agents a pane
/// just started or the idle pool just stopped, each at its own moment.
function snapshot(warmed: Record<string, number>) {
  const touched = (id: string, at: number) => warmed[id] ?? at;
  return [
    summary("hello", "hello>?", "claude", ago(120), touched("hello", ago(119))),
    summary("dude", "hi dude", "codex", ago(60), touched("dude", ago(59))),
    summary("reds", "cg-next-reds", "claude", ago(31), touched("reds", ago(31))),
    summary("adopt", "cg-lane-adopt", "claude", ago(31), touched("adopt", ago(31))),
    // Adopted from another daemon: no turn ended here, so it holds its place from when it came.
    summary("okay", "Okay, great", "codex", null, touched("okay", ago(500)), { createdAt: ago(300) }),
  ].map(sessionEntry);
}

const rows = (sessions: ReturnType<typeof snapshot>) =>
  recentChatCards(sessions, T0, undefined, [], 10).map((card) => `${card.title} ${card.age}`);

test("a workspace switch that warms or stops old chats leaves the Chats order and ages alone", () => {
  const before = rows(snapshot({}));
  expect(before).toEqual(["cg-lane-adopt 31m", "cg-next-reds 31m", "hi dude 1h", "hello>? 2h", "Okay, great 5h"]);
  // One switch warms "hello>?" and the pool stops "Okay, great"; the next warms "hi dude".
  expect(rows(snapshot({ hello: ago(0), okay: ago(0) }))).toEqual(before);
  expect(rows(snapshot({ dude: ago(0), hello: ago(1) }))).toEqual(before);
});

test("a running turn and a chat waiting on the person are activity now", () => {
  const sessions = [
    ...snapshot({}).slice(0, 2),
    sessionEntry(
      summary("live", "live lane", "claude", ago(90), ago(0), {
        status: "running",
        turn: { startedAt: ago(2), prompt: "go", promptId: "p", turnId: "t", turnSeq: 9, client: "c" },
      }),
    ),
  ];
  expect(rows(sessions)[0]).toBe("live lane now");
});

test("a later real turn moves a chat up again", () => {
  const sessions = snapshot({}).map((entry) =>
    entry.sessionId === "hello" ? sessionEntry(summary("hello", "hello>?", "claude", ago(0), ago(0))) : entry,
  );
  expect(rows(sessions)[0]).toBe("hello>? now");
});

test("a chat paused on a permission inside its turn dates from the pause, not a draft saved later", () => {
  const waiting = (updatedAt: number) =>
    sessionEntry(
      summary("ask", "asks first", "claude", ago(90), updatedAt, {
        status: "waiting",
        pendingPermissions: 1,
        inputSince: ago(20),
        turn: { startedAt: ago(25), prompt: "go", promptId: "p", turnId: "t", turnSeq: 9, client: "c" },
      }),
    );
  const age = (entry: ReturnType<typeof waiting>) =>
    recentChatCards([entry], T0, undefined, [], 10).map((card) => card.age);
  expect(age(waiting(ago(0)))).toEqual(age(waiting(ago(20))));
  expect(age(waiting(ago(0)))).toEqual(["20m"]);
});
