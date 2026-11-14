// l10n-allow-file: test fixture replies, not shipped UI.
// Leo, 2026-11-14, on the same "A few updates:" report drawn twice back to back in his chat: "why did
// u send this twice?". A Stop hook (leo-workspace notes-first) blocked the agent's stop over one line,
// and the agent sent its whole reply again. acpmux now records the second reply as replacing the
// first (`message_superseded`, reason `stop_hook`, hub/stream.rs), and the pane streams it into the
// first one's row (direct.ts `reviseSupersededMessage`).
//
// claude-stop-hook-resend.ndjson is that turn as acpmux records it: a reply, Claude Code's synthetic
// "Stop hook feedback" line, the hub's `stop_hook_feedback` update and `message_superseded`, then the
// reply again with one line changed.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { rowsFromRecording } from "../src/gallery/fixtures/recording";
import { revisedReplyText } from "../src/agent-session/acpmux/conversation/RevisedReply";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const RECORDING = readFileSync(
  new URL("../src/gallery/fixtures/recordings/claude-stop-hook-resend.ndjson", import.meta.url),
  "utf8",
);
const lines = RECORDING.trim().split("\n");
const replies = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "assistant" && row.text?.trim());

test("a reply sent again after a Stop hook draws once, in the first one's row", async () => {
  const rows = await rowsFromRecording(RECORDING, "claude");
  const drawn = replies(rows);
  expect(drawn.map((row) => row.id)).toEqual(["assistant-turn-1.1a1dc1fdab9.1"]);
  const [reply] = drawn;
  expect(reply!.text).toContain("still unconfirmed");
  expect(reply!.text).not.toContain("it's fixed now");
  expect(reply!.revisedFrom?.text).toContain("it's fixed now");
  expect(reply!.revisedFrom?.reason).toContain("Rewrite only that sentence");
  expect(revisedReplyText(reply!)).toEqual({ text: reply!.text!, revising: false });
});

test("while the new reply streams, its row shows the first one whole", async () => {
  // The turn cut after the new reply's first chunk: the slot still reads the first reply.
  const cut = lines.filter((line) => Number(JSON.parse(line).seq) <= 12).join("\n");
  const rows = await rowsFromRecording(cut, "claude");
  const drawn = replies(rows);
  expect(drawn).toHaveLength(1);
  const shown = revisedReplyText(drawn[0]!);
  expect(shown.revising).toBe(true);
  expect(shown.text).toContain("it's fixed now");
  expect(shown.text).toContain("Restart numbers");
});

test("two replies with no Stop hook between them are both drawn", async () => {
  const plain = lines.filter((line) => !/"seq":(8|9|10|11),/.test(line)).join("\n");
  const rows = await rowsFromRecording(plain, "claude");
  expect(replies(rows)).toHaveLength(2);
  expect(replies(rows).some((row) => row.revisedFrom)).toBe(false);
});
