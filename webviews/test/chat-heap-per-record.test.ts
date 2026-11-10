// l10n-allow-file: test fixtures.
// A long open chat holds a constant amount of heap per record: the same batch of records played again
// and again (a turn with a streamed shell, whose every update carries the whole output so far, and a read
// with a large result) adds the same heap each time, close to the bytes the batch shows, never more as the
// chat grows. Held records once kept each streamed update's whole content (the heap per streamed output
// grew with the square of its length); transcript-replay.bench.ts `transcript_replay.long.heap_mb` is the
// page's number.
import { heapStats } from "bun:jsc";
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, thinStreamedOutputs, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const SESSION = "heap-chat";
const UPDATES = 30;
const LINES = 40;
const READ_CHARS = 512 * 1024;

function batch(turn: number, seq: number): { events: EventRecord[]; shownChars: number } {
  const events: EventRecord[] = [];
  const at = 1_000_000 + turn * 10_000;
  const update = (value: Record<string, unknown>): EventRecord => ({
    sessionId: SESSION,
    seq: seq + events.length + 1,
    at: at + events.length,
    dir: "in",
    kind: String(value.sessionUpdate),
    msg: { method: "session/update", params: { sessionId: SESSION, update: value } },
  });
  events.push({
    sessionId: SESSION,
    seq: seq + 1,
    at,
    dir: "mux",
    kind: "user_message",
    msg: { text: `Turn ${turn}: run the tests` },
  });
  const shell = `shell-${turn}`;
  events.push(
    update({ sessionUpdate: "tool_call", toolCallId: shell, kind: "execute", title: "Run tests", status: "in_progress" }),
  );
  let log = "";
  for (let step = 0; step < UPDATES; step += 1) {
    // ASCII, so every engine holds a char in a byte; a fresh string per turn, as an agent's output is.
    for (let line = 0; line < LINES; line += 1) log += `ok turn ${turn} case ${step * LINES + line} keeps it stable\n`;
    events.push(
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: shell,
        status: "in_progress",
        content: [{ type: "content", content: { type: "text", text: log } }],
      }),
    );
  }
  events.push(update({ sessionUpdate: "tool_call_update", toolCallId: shell, status: "completed" }));
  const body = `// turn ${turn}\n` + "x".repeat(READ_CHARS);
  events.push(
    update({
      sessionUpdate: "tool_call",
      toolCallId: `read-${turn}`,
      kind: "read",
      title: `Read src/turn${turn}.ts`,
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: body } }],
    }),
  );
  events.push(update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Turn ${turn} done.` } }));
  return { events, shownChars: log.length + body.length };
}

function heapBytes(): number {
  Bun.gc(true);
  Bun.gc(true);
  // Strings' contents included (the engine's extra memory).
  return heapStats().heapSize;
}

test("a streamed call's rows end the same after a fold from the start, its earlier updates held without content", () => {
  let shown: AcpmuxSnapshot | undefined;
  const client = AcpmuxDirectClient.fed(SESSION, (snapshot) => (shown = snapshot));
  const { events } = batch(1, 0);
  client.feed(events, "live");
  const output = (snapshot?: AcpmuxSnapshot) =>
    snapshot?.rows.flatMap((row) => row.items ?? []).find((item) => item.tool?.id === "shell-1")?.tool?.output;
  const live = output(shown);
  expect(live?.split("\n").length).toBe(UPDATES * LINES + 1);
  const held = (client as unknown as { events: EventRecord[] }).events;
  const withContent = held.filter((event) => event.kind === "tool_call_update" && event.msg.params.update.content);
  // The newest update keeps the call's content; the ones before it are moot.
  expect(withContent.length).toBe(1);
  // Folding again from the held records (an older page in front) draws the same output.
  client.feed([], "older");
  expect(output(shown)).toBe(live);
  // The same records read as a page (an open) are thinned as they are folded, to the same rows.
  let opened: AcpmuxSnapshot | undefined;
  const reader = AcpmuxDirectClient.fed(SESSION, (snapshot) => (opened = snapshot));
  reader.feed(events, "snapshot");
  expect(output(opened)).toBe(live);
  const page = (reader as unknown as { events: EventRecord[] }).events;
  expect(page.filter((event) => event.kind === "tool_call_update" && event.msg.params.update.content).length).toBe(1);
  // Nothing to thin: the same array back.
  expect(thinStreamedOutputs(page)).toBe(page);
});

test("heap per batch of records stays flat as the chat grows, near what the batch shows", () => {
  const client = AcpmuxDirectClient.fed(SESSION, () => {});
  const batches = 12;
  let seq = 0;
  // A first batch warms the code paths and caches that are paid once.
  const first = batch(0, seq);
  client.feed(first.events, "live");
  seq += first.events.length;
  let before = heapBytes();
  const added: number[] = [];
  let shown = 0;
  for (let turn = 1; turn <= batches; turn += 1) {
    const next = batch(turn, seq);
    seq += next.events.length;
    shown = next.shownChars;
    client.feed(next.events, "live");
    const after = heapBytes();
    added.push(after - before);
    before = after;
  }
  const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const perBatch = mean(added);
  // The least-squares slope of the heap each batch adds, over the batches: zero when each costs the same.
  const xs = added.map((_, index) => index);
  const mx = mean(xs);
  const slope =
    xs.reduce((sum, x, index) => sum + (x - mx) * (added[index]! - perBatch), 0) /
    xs.reduce((sum, x) => sum + (x - mx) ** 2, 0);
  const report = `added per batch (KB): ${added.map((bytes) => Math.round(bytes / 1024)).join(" ")}; shown ${Math.round(shown / 1024)} KB`;
  // Growth per batch under 2% of a batch's cost per batch (GC noise), and a batch costs under twice what it shows.
  expect(slope, report).toBeLessThan(0.02 * Math.max(perBatch, shown));
  expect(perBatch, report).toBeLessThan(2 * shown);
  client.dispose();
});
