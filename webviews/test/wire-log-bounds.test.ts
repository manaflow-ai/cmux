// The wire log keeps at most MAX_PAYLOAD_CHARS of a message, as a string of its own (wire.ts ownCopy): a slice of
// a long message would keep the whole message alive, so a god chat's MB pages stayed in memory behind a 16K entry.
import { expect, test } from "bun:test";
import { AcpWireLog, MAX_PAYLOAD_CHARS, MAX_TEXT_CHARS, ownCopy } from "../src/agent-session/acpmux/wire";

test("ownCopy gives back the same text, a cut surrogate pair included", () => {
  const text = `${"a".repeat(10)}\u{1F600}${"b".repeat(10)}`;
  for (const end of [0, 10, 11, 12, text.length]) expect(ownCopy(text.slice(0, end))).toBe(text.slice(0, end));
});

test("a long message is logged as its first MAX_PAYLOAD_CHARS, and the log's text stays bounded", () => {
  const log = new AcpWireLog(
    () => 0,
    () => 0,
  );
  const message = JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { text: "x".repeat(400_000) } });
  for (let index = 0; index < 200; index++) log.received(message);
  const entries = log.entries();
  expect(entries.at(-1)!.text).toBe(message.slice(0, MAX_PAYLOAD_CHARS));
  expect(entries.at(-1)!.size).toBe(message.length);
  expect(entries.at(-1)!.truncated).toBe(true);
  const held = entries.reduce((sum, entry) => sum + (entry.text?.length ?? 0), 0);
  expect(held).toBeLessThanOrEqual(MAX_TEXT_CHARS);
  expect(log.stats().textChars).toBe(held);
  expect(log.stats().oldestSeq).toBe(entries[0]!.seq);
  expect(log.stats().dropped).toBe(200 - entries.length);
});
