// l10n-allow-file: test fixtures.
// The page's one transcript gate (transcriptGate.ts): whichever source a client draws a chat from,
// and whichever client of the page draws it, the rows on screen never go back to an older copy.
import { beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import {
  passTranscript,
  resetTranscriptGateForTests,
  transcriptGateStats,
} from "../src/agent-session/acpmux/transcriptGate";

const say = (seq: number, text: string): EventRecord => ({
  seq,
  at: 1_000 + seq,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const prompt = (seq: number, text: string): EventRecord => ({
  seq,
  at: 1_000 + seq,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});
const row = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "assistant",
  ...extra,
});

beforeEach(resetTranscriptGateForTests);

test("a new client drawing an older copy of the chat never replaces the rows on screen", () => {
  const frames: string[] = [];
  const draw = (snapshot: AcpmuxSnapshot) =>
    frames.push(
      snapshot.rows
        .map((row) => row.text ?? "")
        .filter(Boolean)
        .join("|"),
    );
  // The chat as read live: two turns.
  const live = AcpmuxDirectClient.fed("gate-chat", draw);
  live.feed(
    [prompt(1, "First ask"), say(2, "First reply."), prompt(3, "Second ask"), say(4, "Second reply.")],
    "snapshot",
  );
  const newest = frames.at(-1)!;
  expect(newest).toContain("Second reply.");
  live.dispose();
  // The connection drops; the page's next client draws an old saved copy before its attach lands,
  // five times over, as a flaky socket does.
  for (let drop = 0; drop < 5; drop += 1) {
    const next = AcpmuxDirectClient.fed("gate-chat", draw);
    next.feed([prompt(1, "First ask"), say(2, "First reply.")], "snapshot");
    expect(frames.at(-1)).toBe(newest);
    next.dispose();
  }
  // The attach brings the chat past what was shown: it draws.
  const attached = AcpmuxDirectClient.fed("gate-chat", draw);
  attached.feed(
    [
      prompt(1, "First ask"),
      say(2, "First reply."),
      prompt(3, "Second ask"),
      say(4, "Second reply."),
      say(5, " More."),
    ],
    "snapshot",
  );
  expect(frames.at(-1)).toContain("More.");
  // Never once did a frame lose the second turn after it was shown.
  const shownAt = frames.findIndex((frame) => frame.includes("Second reply."));
  expect(frames.slice(shownAt).every((frame) => frame.includes("Second reply."))).toBe(true);
  expect(transcriptGateStats.refused).toBe(5);
});

test("a replay seeks back freely and leaves the live chat's gate alone", () => {
  let rows: AcpmuxRow[] = [];
  const events = [prompt(1, "Ask"), say(2, "Reply one."), prompt(3, "Again"), say(4, "Reply two.")];
  const replay = AcpmuxDirectClient.replay("gate-replay", events, (snapshot) => (rows = snapshot.rows));
  replay.seekReplay(4);
  expect(rows.some((row) => row.text?.includes("Reply two."))).toBe(true);
  replay.seekReplay(2);
  expect(rows.some((row) => row.text?.includes("Reply two."))).toBe(false);
  expect(transcriptGateStats.refused).toBe(0);
});

test("the gate keeps what the person just sent and starts over for a chat made again", () => {
  const shownRows = [row("a"), row("b")];
  expect(passTranscript("s", 7, 10, shownRows)).toBe(shownRows);
  // An older copy with a prompt the page is sending: the shown rows, then the prompt.
  const sending = row("p", { kind: "user", pending: true, text: "now" });
  expect(passTranscript("s", 7, 4, [row("a"), sending]).map((r) => r.id)).toEqual(["a", "b", "p"]);
  // An older copy with nothing of its own: the very rows already shown.
  expect(passTranscript("s", undefined, 0, [])).toBe(shownRows);
  // The same id made again (another generation) counts its records from 1: its rows draw.
  const remade = [row("x")];
  expect(passTranscript("s", 8, 2, remade)).toBe(remade);
  // Another chat is its own.
  const other = [row("o")];
  expect(passTranscript("t", undefined, 1, other)).toBe(other);
  expect(passTranscript(undefined, undefined, 0, [])).toEqual([]);
});
