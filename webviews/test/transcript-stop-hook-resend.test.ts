// l10n-allow-file: test fixture replies, not shipped UI.
// Leo, 2026-11-15, on the same reply drawn two and three times in a row in his NEXT agent chat:
// "this is super wack the way we're scrolling up infinitely :(". A Stop hook (leo-workspace
// notes-first) blocked the agent's stop over one line, and the agent sent its whole reply again.
// acpmux records the second reply as replacing the first (`message_superseded`, reason `stop_hook`,
// hub/stream.rs), and the pane drops the first reply's rows, as it does for a Codex retry.
//
// claude-stop-hook-resend.ndjson is that turn as acpmux records it: a reply, Claude Code's synthetic
// "Stop hook feedback" line, the `stop_hook_feedback` update and `message_superseded`, then the
// reply again with one line changed.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { rowsFromRecording } from "../src/gallery/fixtures/recording";
import { turnCopyParts } from "../src/agent-session/acpmux/conversation/turnCopy";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const RECORDING = readFileSync(
  new URL("../src/gallery/fixtures/recordings/claude-stop-hook-resend.ndjson", import.meta.url),
  "utf8",
);
const lines = RECORDING.trim().split("\n");
const replies = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "assistant" && row.text?.trim());
const copied = (rows: AcpmuxRow[]) =>
  (turnCopyParts(rows) ?? []).map((part) => ("text" in part ? part.text : "")).join("\n");

test("a reply sent again after a Stop hook draws once, the new one", async () => {
  const rows = await rowsFromRecording(RECORDING, "claude");
  const drawn = replies(rows);
  expect(drawn).toHaveLength(1);
  expect(drawn[0]!.text).toContain("still unconfirmed");
  expect(drawn[0]!.text).not.toContain("it's fixed now");
  // The turn's Copy is the new reply only.
  expect(copied(rows)).toContain("still unconfirmed");
  expect(copied(rows)).not.toContain("it's fixed now");
});

test("the hook's own records draw no row", async () => {
  const rows = await rowsFromRecording(RECORDING, "claude");
  expect(rows.some((row) => row.text?.includes("Rewrite only that sentence"))).toBe(false);
});

test("two replies with no Stop hook between them are both drawn", async () => {
  const plain = lines.filter((line) => !/"seq":(8|9|10|11),/.test(line)).join("\n");
  const rows = await rowsFromRecording(plain, "claude");
  expect(replies(rows)).toHaveLength(2);
});
