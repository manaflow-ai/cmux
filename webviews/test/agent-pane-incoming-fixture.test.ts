// l10n-allow-file: test fixture messages, not shipped UI.
// `debug.agent_pane seed_rows` with `fixture: "incoming"` puts received agent messages in the real
// app's transcript, so a capture mini can show the received-message card (IncomingMessageCard.tsx)
// at a commit: a cmux agent message whose prompt is the full envelope, arriving while a turn runs,
// and one from a chat here whose name opens it.
import { expect, test } from "bun:test";
import { incomingRows } from "../src/agent-session/acpmux/incomingFixture";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";

test("the incoming fixture's messages are cards whose body is the message, not the envelope", () => {
  const rows = incomingRows(Date.UTC(2026, 9, 21, 9));
  const cards = rows.filter((row) => row.kind === "user" && row.incoming?.kind === "message");
  expect(cards.length).toBe(2);
  for (const row of cards) {
    if (row.incoming?.kind !== "message") throw new Error("not a message");
    const { text, raw } = row.incoming.message;
    expect(row.untyped).toBe(true);
    expect(row.text).toBe(text);
    expect(raw).not.toBe(text);
    expect(raw).toContain(text);
  }
  const [envelope] = cards;
  if (envelope?.incoming?.kind !== "message") throw new Error("not a message");
  expect(envelope.incoming.message.raw).toStartWith("[cmux agent message] from ");
  expect(envelope.incoming.message.raw).toContain("Message id: msg_");
  expect(cards[1]?.incoming?.kind === "message" && cards[1].incoming.message.sessionId).toBeTruthy();
});

test("the fixture's envelope is the one acpmux delivers: the page reads it back to the same body", () => {
  const rows = incomingRows(Date.UTC(2026, 9, 21, 9));
  const card = rows.find((row) => row.kind === "user" && row.incoming?.kind === "message");
  if (card?.incoming?.kind !== "message") throw new Error("no card");
  const { raw, text, msgId } = card.incoming.message;
  const read = incomingPrompt(raw, {
    _meta: { provenance: { kind: "agent_message", from: "subsession-visibility", msgId } },
  });
  expect(read?.kind).toBe("message");
  if (read?.kind !== "message") return;
  expect(read.message.text).toBe(text);
});

test("ids are unique, and times only move forward", () => {
  const rows = incomingRows(Date.UTC(2026, 9, 21, 9));
  expect(new Set(rows.map((row) => row.id)).size).toBe(rows.length);
  for (let index = 1; index < rows.length; index += 1)
    expect(rows[index]!.at).toBeGreaterThanOrEqual(rows[index - 1]!.at);
});
