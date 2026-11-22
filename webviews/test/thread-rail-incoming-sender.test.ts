// l10n-allow-file: test fixture prompts and senders, not shipped UI.
// Another session's message keeps its tick on the prompt rail, but the tick and its card say who sent
// it (model.ts promptSender), so it never reads as the person's own prompt (Leo, 2026-10-27:
// "Messages sent from other sessions ... shouldn't they be designated as like a special sort of
// thing?"). Before: the tick and card carried the message's words alone, as if the person typed them.
import { expect, test } from "bun:test";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { minimapTurns, promptSender } from "../src/agent-session/acpmux/threadMinimap/model";

const CHAT = "0190a000-0000-7000-8000-0000000c0de2";
const prompt = (n: number, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `user-${n}`,
  version: 1,
  at: n,
  kind: "user",
  text,
  promptId: `p-${n}`,
  ...extra,
});
const reply = (n: number): AcpmuxRow => ({ id: `a-${n}`, version: 1, at: n, kind: "assistant", text: `Answer ${n}` });

function fromSession(n: number, sender: string, body: string): AcpmuxRow {
  const incoming = incomingPrompt(body, {
    _meta: { provenance: { kind: "session_message", from: `${sender}-id`, fromName: sender, to: "me" } },
  });
  if (incoming?.kind !== "message") throw new Error(`not a message: ${JSON.stringify(incoming)}`);
  return prompt(n, incoming.message.text, { incoming, resend: body });
}

test("another session's message keeps its tick and names its sender; the person's prompts name none", () => {
  const rows = [
    prompt(1, "Fix the sidebar"),
    reply(1),
    fromSession(2, "hq-mirror", "HQ mirror stash cleared on the helper's branch."),
    reply(2),
    prompt(3, "Thanks"),
    reply(3),
  ];
  expect(promptSender(rows[2]!)).toBe("hq-mirror");
  expect(promptSender(rows[0]!)).toBeUndefined();
  const { turns, ticks } = minimapTurns(rows, CHAT);
  expect(turns.map((turn) => turn.from)).toEqual([undefined, "hq-mirror", undefined]);
  expect(ticks.map((tick) => tick.from)).toEqual([undefined, "hq-mirror", undefined]);
  // A person's turn keeps the shape it had: no `from` key at all.
  expect("from" in turns[0]!).toBe(false);
  expect(turns[1]!.prompt).toBe("HQ mirror stash cleared on the helper's branch.");
});

test("a tick that learns its sender later is a new tick object", () => {
  const plain = [prompt(1, "HQ mirror stash cleared.")];
  const first = minimapTurns(plain, CHAT);
  const named = [fromSession(1, "hq-mirror", "HQ mirror stash cleared.")];
  const second = minimapTurns(named, CHAT, first);
  expect(second.ticks[0]).not.toBe(first.ticks[0]);
  expect(second.ticks[0]!.from).toBe("hq-mirror");
});
