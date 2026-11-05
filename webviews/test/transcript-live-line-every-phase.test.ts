// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// The running turn's live line is the transcript's last row from the person's send to the reply,
// in every phase, and it never leaves and comes back (Leo, 2026-11-04, on his chat mid-turn: "why
// does it not display Thinking or anything here???", "it appears and disappears????", "WHY DOES IT
// LOOK KLIKE YOU'RE NOT RESPONDING HERE???", "this is bad. it looks like you're not working.").
//
// - A prompt sent after a turn ended draws Thinking under it from the send, before acpmux's record
//   of it (and the turn it opens) reaches the pane, whether or not the chat already reads as working.
// - Thinking, a thought streaming, a call running, between calls, a steer sent mid-turn (waiting, then
//   read), the reply streaming: the line is last, with the one id the send gave it.
// - A finished turn with nothing sent after it draws no line.
// Gallery: agent-pane.live-line-every-phase.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 4, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (id: string, status: string, extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id, startedAt: START, ...extra },
});
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });

/// The chat before: a turn that ended with its reply.
const before: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Deploy main on this host" }),
  row("a-0", "assistant", 10, { text: "Deployed." }),
  row("s-0", "turnSummary", 11, { status: "completed", durationMs: 11_000, toolCount: 0 }),
];
const sent = row("u-1", "user", 60, { text: "but why has it taken so long?", pending: true });
const opened = { ...sent, pending: undefined, version: 2 };
const steer = row("u-2", "user", 70, { text: "WHY DID YOU NOT RESPOND THERE", pending: true });
const steerWaiting = { ...steer, pending: undefined, steer: "waiting" as const, version: 2 };
const steerRead = { ...steerWaiting, steer: "landed" as const, version: 3 };

const view = (rows: AcpmuxRow[], working: boolean) =>
  turnView(rows, new Set(), { working, agentFamily: "claude", now: START + 90_000 });

/// Each phase of a running turn, as the pane's rows and its working state stand then.
const phases: [name: string, rows: AcpmuxRow[], working: boolean][] = [
  ["sent, acpmux has not written it", [...before, sent], false],
  ["sent, the chat reads as working before the prompt's record", [...before, sent], true],
  ["the turn opened: Thinking", [...before, opened], true],
  ["a thought streams", [...before, opened, row("t-1", "activity", 62, { items: [thought("Looking")] })], true],
  [
    "a call runs",
    [...before, opened, row("t-1", "activity", 62, { items: [thought("Looking"), call("git log", "in_progress")] })],
    true,
  ],
  [
    "between calls",
    [...before, opened, row("t-1", "activity", 62, { items: [thought("Looking"), call("git log", "completed")] })],
    true,
  ],
  [
    "a steer sent mid-turn, not taken yet",
    [...before, opened, row("t-1", "activity", 62, { items: [call("git log", "completed")] }), steer],
    true,
  ],
  [
    "the steer waits for the agent's step",
    [...before, opened, row("t-1", "activity", 62, { items: [call("git log", "completed")] }), steerWaiting],
    true,
  ],
  [
    "the agent read the steer and runs a call",
    [
      ...before,
      opened,
      row("t-1", "activity", 62, { items: [call("git log", "completed")] }),
      steerRead,
      row("t-2", "activity", 75, { items: [call("leo-forward --to lane", "in_progress")] }),
    ],
    true,
  ],
  [
    "the reply streams",
    [
      ...before,
      opened,
      row("t-1", "activity", 62, { items: [call("git log", "completed")] }),
      steerRead,
      row("t-2", "activity", 75, { items: [call("leo-forward --to lane", "completed")] }),
      row("a-1", "assistant", 85, { text: "I did answer both." }),
    ],
    true,
  ],
];

test("the live line is the last row in every phase of a running turn, with the id the send gave it", () => {
  for (const [name, rows, working] of phases) {
    const last = view(rows, working).at(-1);
    expect({ name, kind: last?.kind, id: last?.id }).toEqual({ name, kind: THINKING, id: "thinking-live" });
  }
});

test("a prompt sent after a turn ended reads Thinking under it from the send, timed from the send", () => {
  const shaped = view([...before, sent], false);
  expect(shaped.map((entry) => entry.id).slice(-2)).toEqual(["u-1", "thinking-live"]);
  expect(shaped.at(-1)!.at).toBe(sent.at);
  // Held behind its agent's start: the start look, with no time yet (cmux#30642).
  const queued = view([...before, { ...sent, queued: "starting" } as AcpmuxRow], false).at(-1)!;
  expect(queued).toMatchObject({ id: "thinking-live", untimed: true });
});

test("a failed send, another session's message, and a finished turn draw no live line", () => {
  const failed = view([...before, { ...sent, failed: true }], false).at(-1)!;
  expect(failed.kind).not.toBe(THINKING);
  const incoming = { kind: "message" as const, message: { name: "Helper", text: "Deployed", raw: "Deployed" } };
  const message = view([...before, { ...sent, incoming }], false);
  expect(message.some((entry) => entry.kind === THINKING)).toBe(false);
  expect(view(before, false).some((entry) => entry.kind === THINKING)).toBe(false);
});
