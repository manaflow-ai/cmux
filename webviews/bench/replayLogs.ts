// l10n-allow-file: recorded and generated agent chats for a bench, not shipped UI.
// The logs the transcript replay bench (transcript-replay.bench.ts) plays into the real pane: acpmux session logs,
// one EventRecord per record exactly as `_acpmux/attach` and `_acpmux/event` carry them, keyed by `seq` (1, 2, 3...
// per session, as acpmux numbers a session's log), so a recorded daemon log lines up with these record for record.
//   mock:<id>   every seeded `?mock` chat (mockFixture.ts: the worked turn and each session's history)
//   recorded    the recorded acpmux chat the replay screen and gallery use (replay/replayFixture.ts)
//   long        a real-shaped long session (loadFixture.ts's heavy turns: reads, large edits, long shell logs),
//               thousands of rows, with streamed turns at checkpoints: a reply streamed token by token and a shell
//               call whose output streams in, each one a measured burst (`bursts`) at that many rows
// Pure: no page, no timers.
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { loadTurn, sourceFile } from "../src/agent-session/acpmux/loadFixture";
import {
  mockSessions,
  sessionHistory,
  sessionSummary,
  workedTurn,
  WORKED_SESSION,
  type MockSession,
  type SeedStep,
} from "../src/agent-session/acpmux/mockFixture";
import { REPLAY_SESSION, replayFixtureEvents } from "../src/agent-session/acpmux/replay/replayFixture";

/// A measured run of records inside a log: from `fromSeq` to `toSeq` (inclusive), each a token (a reply chunk) or a
/// streamed tool output update, played one per painted frame when the transcript already holds `rows` rows.
export type Burst = { kind: "token" | "tool_output"; fromSeq: number; toSeq: number; rows: number };
export type ReplayLog = {
  name: string;
  sessionId: string;
  /// The session as `_acpmux/watch` reports it, without `status` and `turnCount` (the bench sets those).
  summary: Record<string, unknown>;
  events: EventRecord[];
  bursts: Burst[];
};

type Step =
  | { update: Record<string, unknown>; meta?: Record<string, unknown> }
  | { mux: string; msg?: Record<string, unknown> };

/// One record, as acpmux logs it (and mock.ts's `record` builds it).
export function toRecord(sessionId: string, seq: number, at: number, step: Step): EventRecord {
  if ("update" in step)
    return {
      sessionId,
      seq,
      at,
      dir: "in",
      kind: String(step.update.sessionUpdate),
      msg: {
        method: "session/update",
        params: { sessionId, update: step.update, ...(step.meta && { _meta: step.meta }) },
      },
    };
  return { sessionId, seq, at, dir: "mux", kind: step.mux, msg: step.msg ?? {} };
}

/// The seq keys hold: 1, 2, 3... in order, one session, time never running back. Throws with the first record that
/// breaks them, so a fixture that would not line up with a daemon's log never replays.
export function checkSeq(log: Pick<ReplayLog, "name" | "sessionId" | "events">): void {
  let at = -Infinity;
  log.events.forEach((event, index) => {
    const where = `${log.name}: record ${index}`;
    if (event.seq !== index + 1) throw new Error(`${where} has seq ${event.seq}, expected ${index + 1}`);
    if (event.sessionId !== log.sessionId) throw new Error(`${where} is of session ${event.sessionId}`);
    if (!Number.isFinite(event.at) || event.at < at) throw new Error(`${where} goes back in time (${event.at})`);
    at = event.at;
  });
}

/// How many transcript rows the first `count` records make (pure): each prompt, tool call, permission card and run
/// of reply (or thought) chunks is one row. The x axis of work per token.
export function rowsIn(events: readonly EventRecord[], count = events.length): number {
  let rows = 0;
  let previous = "";
  for (const event of events.slice(0, count)) {
    const kind = event.kind;
    if (kind === "user_message" || kind === "tool_call" || kind === "permission_request") rows += 1;
    else if ((kind === "agent_message_chunk" || kind === "agent_thought_chunk") && previous !== kind) rows += 1;
    if (kind !== "tool_call_update") previous = kind;
  }
  return rows;
}

function fromSeed(entry: MockSession, now: number): ReplayLog {
  const steps: SeedStep[] = entry.sessionId === WORKED_SESSION ? workedTurn : sessionHistory(entry);
  const ordered = [...steps].sort((a, b) => b.ago - a.ago);
  const events = ordered.map(({ ago, ...step }, index) =>
    toRecord(entry.sessionId, index + 1, now - ago, step as Step),
  );
  return {
    name: `mock:${entry.sessionId}`,
    sessionId: entry.sessionId,
    summary: sessionSummary(entry, now, 1),
    events,
    bursts: [],
  };
}

/// Every seeded `?mock` chat, as its log.
export function mockLogs(now: number): ReplayLog[] {
  return mockSessions.map((entry) => fromSeed(entry, now));
}

/// The recorded chat (replay/replayFixture.ts), its seq and wall-clock gaps as recorded.
export function recordedLog(): ReplayLog {
  return {
    name: "recorded",
    sessionId: REPLAY_SESSION,
    summary: {
      sessionId: REPLAY_SESSION,
      cwd: "~/code/api",
      title: "Flaky retry test",
      harness: "claude",
      name: "claude",
      updatedAt: Date.UTC(2026, 9, 10, 16, 21, 0),
    },
    events: replayFixtureEvents(),
    bursts: [],
  };
}

const text = (value: string) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } });

/// The words of a streamed reply, split the way a model streams them (a few characters each).
export function tokens(turn: number, count: number): string[] {
  const words = (
    `Turn ${turn}: the guard now runs before the total, so a value past the ceiling stops at the first pass. ` +
    "I kept `limit` as an alias and reran the suite; every case passes, including the two that hit the cap. " +
    sourceFile(turn, 4).replace(/\n/g, " ")
  ).split(/(?<= )/);
  return Array.from({ length: count }, (_, index) => words[index % words.length]!);
}

/// A real-shaped long session: `turns` heavy finished turns (loadFixture.ts), and at each of `checkpoints` (turn
/// indices) a streamed turn: a reply of `tokenCount` tokens, then a shell call whose output streams in
/// `outputUpdates` updates of 40 lines each (acpmux sends a call's whole content each time, so each update is
/// longer). The records are 1 minute of wall clock per turn apart, a second per streamed burst.
export function longLog(
  opts: { turns?: number; checkpoints?: number[]; tokenCount?: number; outputUpdates?: number } = {},
): ReplayLog {
  const turns = opts.turns ?? 600;
  const checkpoints = new Set(
    opts.checkpoints ?? [2, ...[1, 2, 3, 4].map((fifth) => Math.floor((turns * fifth) / 5)), turns - 1],
  );
  const tokenCount = opts.tokenCount ?? 80;
  const outputUpdates = opts.outputUpdates ?? 30;
  const sessionId = "replay-long";
  const start = Date.UTC(2026, 10, 3, 9, 0, 0);
  const events: EventRecord[] = [];
  const bursts: Burst[] = [];
  const push = (at: number, step: Step) => events.push(toRecord(sessionId, events.length + 1, at, step));
  for (let turn = 0; turn < turns; turn += 1) {
    const at = start + turn * 60_000;
    if (!checkpoints.has(turn)) {
      for (const step of loadTurn(turn)) push(at, step as Step);
      continue;
    }
    push(at, { mux: "user_message", msg: { text: `Turn ${turn}: stream the fix and rerun the suite` } });
    push(at, { mux: "turn_started" });
    const rows = rowsIn(events);
    const fromToken = events.length + 1;
    tokens(turn, tokenCount).forEach((token, index) => push(at + 1000 + index * 25, { update: text(token) }));
    bursts.push({ kind: "token", fromSeq: fromToken, toSeq: events.length, rows });
    const toolCallId = `replay-stream-${turn}`;
    const command = `bun test src/feature${turn % 40}`;
    push(at + 3000, {
      update: {
        sessionUpdate: "tool_call",
        toolCallId,
        kind: "execute",
        title: `Run ${command}`,
        status: "in_progress",
        rawInput: { command },
      },
    });
    const outputRows = rowsIn(events);
    const fromOutput = events.length + 1;
    let log = "";
    for (let update = 0; update < outputUpdates; update += 1) {
      for (let line = 0; line < 40; line += 1)
        log += `✓ turn ${turn} case ${update * 40 + line} keeps the ${["cache", "queue", "layout", "parser"][line % 4]} stable [${(line % 9) / 10}ms]\n`;
      push(at + 3000 + update * 100, {
        update: {
          sessionUpdate: "tool_call_update",
          toolCallId,
          status: "in_progress",
          content: [{ type: "content", content: { type: "text", text: log } }],
        },
      });
    }
    bursts.push({ kind: "tool_output", fromSeq: fromOutput, toSeq: events.length, rows: outputRows });
    push(at + 7000, {
      update: { sessionUpdate: "tool_call_update", toolCallId, status: "completed", rawOutput: { exit_code: 0 } },
    });
    push(at + 7500, { update: text("\n\nThe suite passes.") });
    push(at + 8000, { mux: "turn_result", msg: { status: "completed" } });
  }
  return {
    name: "long",
    sessionId,
    summary: {
      sessionId,
      cwd: "/mock/project",
      title: `Long session: ${turns} turns`,
      harness: "claude",
      name: "claude",
      updatedAt: start + turns * 60_000,
    },
    events,
    bursts,
  };
}

/// Least-squares slope of y over x (pure); 0 for fewer than two distinct x.
export function slope(points: readonly { x: number; y: number }[]): number {
  const n = points.length;
  if (n < 2) return 0;
  const mx = points.reduce((sum, p) => sum + p.x, 0) / n;
  const my = points.reduce((sum, p) => sum + p.y, 0) / n;
  const sxx = points.reduce((sum, p) => sum + (p.x - mx) ** 2, 0);
  if (sxx === 0) return 0;
  return points.reduce((sum, p) => sum + (p.x - mx) * (p.y - my), 0) / sxx;
}

/// A recorded acpmux session log (pure): JSON lines of SessionEvents, or `_acpmux/events`' / `_acpmux/attach`'s
/// answer ({events: [...]}), as a daemon or a simulated agent writes it. Its seq keys are kept as recorded, so
/// checkSeq refuses a log with a gap (a page of it, say) instead of replaying something the daemon never sent.
export function parseLog(name: string, text: string): ReplayLog {
  const trimmed = text.trim();
  const parsed: unknown = trimmed.startsWith("{") && !trimmed.includes("\n{") ? JSON.parse(trimmed) : undefined;
  const events = (
    parsed && typeof parsed === "object" && Array.isArray((parsed as { events?: unknown }).events)
      ? (parsed as { events: EventRecord[] }).events
      : trimmed.startsWith("[")
        ? (JSON.parse(trimmed) as EventRecord[])
        : trimmed
            .split("\n")
            .filter(Boolean)
            .map((line) => JSON.parse(line) as EventRecord)
  ).sort((a, b) => a.seq - b.seq);
  const sessionId = events[0]?.sessionId ?? name;
  return {
    name,
    sessionId,
    summary: { sessionId, cwd: "/replay", title: name, harness: "claude", name: "claude" },
    events,
    bursts: [],
  };
}
