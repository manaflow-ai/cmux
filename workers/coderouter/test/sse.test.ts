import { describe, expect, test } from "bun:test";
import { drainSseUsage, parseJsonUsage, parseSseUsage, SseUsageScanner } from "../src/sse";

describe("usage extraction", () => {
  test("extracts anthropic message_start and final delta", () => {
    const usage = parseSseUsage(
      "anthropic",
      [
        "event: message_start",
        'data: {"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}',
        "",
        "event: message_delta",
        'data: {"usage":{"output_tokens":4}}',
        "",
        "event: message_delta",
        'data: {"usage":{"output_tokens":8}}',
        "",
      ].join("\n"),
    );
    expect(usage).toEqual({ inputTokens: 10, outputTokens: 8, cacheReadTokens: 3, cacheWriteTokens: 2, estimated: false });
  });

  test("extracts response.completed and final chunk usage", () => {
    const usage = parseSseUsage(
      "openai_api",
      [
        "event: response.completed",
        'data: {"response":{"usage":{"input_tokens":11,"output_tokens":12,"input_tokens_details":{"cached_tokens":5}}}}',
        "",
      ].join("\n"),
    );
    expect(usage).toEqual({ inputTokens: 11, outputTokens: 12, cacheReadTokens: 5, cacheWriteTokens: 0, estimated: false });

    expect(
      parseSseUsage("openai_api", 'data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2}}\n\n'),
    ).toMatchObject({ inputTokens: 1, outputTokens: 2, estimated: false });
  });

  test("returns estimated zeros when usage is missing", () => {
    expect(parseSseUsage("openai_api", "data: {}\n\n").estimated).toBe(true);
    expect(parseJsonUsage("anthropic", {}).estimated).toBe(true);
  });

  test("scans large split streams without retaining completed lines", async () => {
    const scanner = new SseUsageScanner("openai_api");
    const filler = `data: {"noise":"${"x".repeat(64 * 1024)}"}\n\n`;
    scanner.pushText(filler);
    scanner.pushText("event: response.completed\n");
    const usageLine = 'data: {"response":{"usage":{"input_tokens":21,"output_tokens":34,"input_tokens_details":{"cached_tokens":8}}}}\n\n';
    for (let index = 0; index < usageLine.length; index += 7) {
      scanner.pushText(usageLine.slice(index, index + 7));
    }

    expect(scanner.finish()).toEqual({ inputTokens: 21, outputTokens: 34, cacheReadTokens: 8, cacheWriteTokens: 0, estimated: false });
    expect(scanner.maxRetainedLineLength).toBeLessThan(usageLine.length);

    const chunks = [
      "event: response.completed\n",
      'data: {"response":{"usage":{"input_tokens":5,',
      '"output_tokens":6,"input_tokens_details":{"cached_tokens":2}}}}\n\n',
    ];
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const encoder = new TextEncoder();
        for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
        controller.close();
      },
    });
    await expect(drainSseUsage("openai_api", stream)).resolves.toEqual({
      inputTokens: 5,
      outputTokens: 6,
      cacheReadTokens: 2,
      cacheWriteTokens: 0,
      estimated: false,
    });
  });
});
