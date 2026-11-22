// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-21: "it is noticeably bad when you start a new working for whatever and there is no
// space before. we should be able to extremely easily catch this."
//
// Found by replaying this machine's recorded chats through the chat simulator
// (`bun scripts/chat-sim.ts --replay ~/.acpmux/sessions/<id>`, 37 of 278 chats): another agent's
// message opened a turn right under the last reply of the turn before, which drew no footer (a turn
// the agent ran on its own, or one whose footer folded). The message, and then the turn's "Working
// for" line drawn over it, stood 16 px under that reply: the run gap a status line has under prose of
// its own turn, so the new turn read as the reply's tail. Under a footer it stands the block gap
// (transcriptSpacing.ts footer-to-received); now it does under a reply too (transcriptGrid.ts
// MARK_TOPS_TURN).
import { expect, test } from "bun:test";
import { gridMark, layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  MARK_TOPS_TURN,
  TRANSCRIPT_BLOCK_GAP,
  TRANSCRIPT_RUN_GAP,
  baseMark,
  transcriptGap,
} from "../src/agent-session/acpmux/transcriptGrid";

let clock = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (clock += 1_000),
  ...extra,
});
const reply = () => row("reply", "assistant", { text: "The land daemon has all four PRs and retries them." });
const message = (extra: Partial<AcpmuxRow> = {}) =>
  row("user-9", "user", {
    text: "From another agent: reply with each PR's head.",
    incoming: { kind: "message", message: { name: "coord", text: "Reply with each PR's head." } },
    ...extra,
  } as Partial<AcpmuxRow>);
const working = () => row("working-user-9", "working");
const gapsOf = (rows: AcpmuxRow[]) => layoutConversation(rows, 720).gaps!;

test("another agent's message opening a turn stands the block gap under the turn before's last reply", () => {
  const gaps = gapsOf([reply(), message()]);
  expect(gaps[1]).toBe(TRANSCRIPT_BLOCK_GAP);
});

test("the turn's Working for line over that message stands the same block gap", () => {
  const gaps = gapsOf([reply(), working(), message()]);
  expect(gaps[1]).toBe(TRANSCRIPT_BLOCK_GAP);
});

test("a steer into the running turn stays that turn's own line, the run gap under its prose", () => {
  const gaps = gapsOf([reply(), message({ steer: "landed" })]);
  expect(gaps[1]).toBe(TRANSCRIPT_RUN_GAP);
});

test("the mark's bit survives the layout's Uint8Array and leaves the base mark alone", () => {
  const mark = gridMark(message(), reply());
  expect(new Uint8Array([mark])[0]).toBe(mark);
  expect(mark & MARK_TOPS_TURN).toBe(MARK_TOPS_TURN);
  expect(transcriptGap(baseMark(gridMark(reply(), undefined)), mark)).toBe(TRANSCRIPT_BLOCK_GAP);
});
