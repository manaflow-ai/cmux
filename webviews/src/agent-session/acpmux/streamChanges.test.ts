// l10n-allow-file: fixture rows, not shipped UI.
// A frame that streams the reply's text beside a running command's output changes both rows in
// one snapshot (direct.ts `emitInFrame`). The pane draws around it as it does around either alone
// (streamChanges.ts `streamedOnly`): composer-typing.bench.ts L1 drew the pane, the reply's
// content and the transcript once per such frame. Leo: "improve performance (chat, everything
// related)".
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { streamedOnly } from "./streamChanges";
import { drewStreamingRow } from "./streamingRow";

const prompt: AcpmuxRow = { id: "user-1", version: 1, at: 0, kind: "user", text: "run the bench" };
const call = (output: string, extra: Partial<NonNullable<AcpmuxActivity["tool"]>> = {}): AcpmuxRow => ({
  id: "activity-1",
  version: output.length,
  at: 1,
  kind: "activity",
  toolCount: 1,
  streaming: true,
  items: [
    {
      kind: "tool",
      text: "Stream benchmark output",
      tool: {
        id: "call-1",
        title: "Stream benchmark output",
        kind: "execute",
        status: "in_progress",
        command: "benchmark",
        output,
        ...extra,
      },
    },
  ],
});
const reply = (text: string): AcpmuxRow => ({
  id: "assistant-1",
  version: text.length,
  at: 2,
  kind: "assistant",
  text,
  streaming: true,
});
const sessions: never[] = [];
const snapshot = (rows: AcpmuxRow[], rest: Record<string, unknown> = {}): AcpmuxSnapshot =>
  ({ type: "snapshot", protocolVersion: 1, rows, sessions, ...rest }) as unknown as AcpmuxSnapshot;

afterEach(() => drewStreamingRow(undefined, undefined));

test("a reply's text alone draws through its row", () => {
  const drawn = snapshot([prompt, call("line 0\n"), reply("Hello")]);
  drewStreamingRow("assistant-1", "Hello");
  const next = snapshot([prompt, drawn.rows[1]!, reply("Hello there")]);
  expect(streamedOnly(drawn, drawn, next)).toEqual({ text: 2 });
});

test("the reply's text and the command's output in one frame draw through their rows", () => {
  const drawn = snapshot([prompt, call("line 0\n"), reply("Hello")]);
  drewStreamingRow("assistant-1", "Hello");
  const next = snapshot([prompt, call("line 0\nline 1\n"), reply("Hello there")]);
  expect(streamedOnly(drawn, drawn, next)).toEqual({
    text: 2,
    call: { id: "call-1", output: "line 0\nline 1\n", before: "line 0\n" },
  });
});

test("frames after one the pane went around compare with the frame before them", () => {
  const drawn = snapshot([prompt, call("line 0\n"), reply("Hello")]);
  drewStreamingRow("assistant-1", "Hello");
  const received = snapshot([prompt, call("line 0\nline 1\n"), reply("Hello there")]);
  const next = snapshot([prompt, call("line 0\nline 1\nline 2\n"), reply("Hello there, again")]);
  expect(streamedOnly(drawn, received, next)?.call?.before).toBe("line 0\nline 1\n");
  // The reply's text alone, after its output went around the pane.
  const textOnly = snapshot([prompt, received.rows[1]!, reply("Hello there, again")]);
  expect(streamedOnly(drawn, received, textOnly)).toEqual({ text: 2 });
});

test("the client's per-snapshot projections do not count as a change", () => {
  const drawn = snapshot([prompt, call("line 0\n"), reply("Hello")], {
    settled: { lastSeq: 4, forkSeqs: [] },
    connection: "agent_message_chunk",
  });
  drewStreamingRow("assistant-1", "Hello");
  const next = snapshot([prompt, call("line 0\nline 1\n"), reply("Hello there")], {
    settled: { lastSeq: 4, forkSeqs: [] },
    connection: "tool_call_update",
  });
  expect(streamedOnly(drawn, drawn, next)?.text).toBe(2);
});

test("anything else draws the pane", () => {
  const drawn = snapshot([prompt, call("line 0\n"), reply("Hello")]);
  drewStreamingRow("assistant-1", "Hello");
  const grown = (output: AcpmuxRow, text = "Hello there") => snapshot([prompt, output, reply(text)]);
  // A pane draw is pending: the output's row would draw from rows older than its entry.
  expect(streamedOnly(drawn, drawn, grown(call("line 0\nline 1\n")), true)).toBeUndefined();
  // The command ended.
  expect(streamedOnly(drawn, drawn, grown(call("line 0\nline 1\n", { status: "completed" })))).toBeUndefined();
  // The output names a link the header reads.
  expect(streamedOnly(drawn, drawn, grown(call("line 0\nhttp://localhost:5173/\n")))).toBeUndefined();
  // The reply's text was replaced, not grown.
  expect(streamedOnly(drawn, drawn, grown(call("line 0\nline 1\n"), "Goodbye"))).toBeUndefined();
  // Another field changed.
  expect(streamedOnly(drawn, drawn, snapshot(grown(call("line 0\nline 1\n")).rows, { title: "x" }))).toBeUndefined();
  // The transcript drew the reply shaped, not as the client holds it.
  drewStreamingRow("assistant-1", "Hel");
  expect(streamedOnly(drawn, drawn, grown(call("line 0\nline 1\n")))).toBeUndefined();
});
