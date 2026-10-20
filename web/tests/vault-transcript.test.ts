import { describe, expect, test } from "bun:test";
import {
  extractTranscriptMessages,
  TranscriptLineParser,
  type TranscriptMessage,
} from "../services/vault/transcript";

describe("vault transcript JSONL parsing", () => {
  test("extracts claude, codex, and pi style JSONL messages while skipping garbage", () => {
    const jsonl = [
      "not-json",
      JSON.stringify({
        type: "assistant",
        message: {
          role: "assistant",
          content: [{ type: "text", text: "Claude answer" }],
        },
      }),
      JSON.stringify({
        role: "user",
        content: "Run the tests",
      }),
      JSON.stringify({
        payload: {
          role: "assistant",
          content: [{ text: "Pi first line" }, { text: "Pi second line" }],
        },
      }),
      JSON.stringify({
        payload: {
          content: "Missing role",
        },
      }),
    ].join("\n");

    expect(extractTranscriptMessages(jsonl)).toEqual([
      { role: "assistant", text: "Claude answer" },
      { role: "user", text: "Run the tests" },
      { role: "assistant", text: "Pi first line\nPi second line" },
    ]);
  });

  test("handles messages split across chunks", () => {
    const messages: TranscriptMessage[] = [];
    const parser = new TranscriptLineParser((message) => messages.push(message));

    parser.feed('{"role":"user","content":"hel');
    parser.feed('lo"}\n{"message":{"role":"assistant","content":[{"text":"wor');
    parser.feed('ld"}]}}\n');
    parser.finish();

    expect(messages).toEqual([
      { role: "user", text: "hello" },
      { role: "assistant", text: "world" },
    ]);
  });

  test("handles CRLF line endings across chunk boundaries", () => {
    const messages: TranscriptMessage[] = [];
    const parser = new TranscriptLineParser((message) => messages.push(message));

    parser.feed(`${JSON.stringify({ role: "user", content: "one" })}\r`);
    parser.feed(`\n${JSON.stringify({ role: "assistant", content: "two" })}\r\n`);
    parser.finish();

    expect(messages).toEqual([
      { role: "user", text: "one" },
      { role: "assistant", text: "two" },
    ]);
  });

  test("handles a giant single line when the stream finishes", () => {
    const text = "x".repeat(128 * 1024);
    const messages: TranscriptMessage[] = [];
    const parser = new TranscriptLineParser((message) => messages.push(message));

    parser.feed(JSON.stringify({ role: "assistant", content: text }).slice(0, 8192));
    parser.feed(JSON.stringify({ role: "assistant", content: text }).slice(8192));
    parser.finish();

    expect(messages).toEqual([{ role: "assistant", text }]);
  });
});
