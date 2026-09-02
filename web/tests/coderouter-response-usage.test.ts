import { describe, expect, test } from "bun:test";
import { __test, observeModelUsage } from "../services/coderouter/responseUsage";

// Usage observation across both stream dialects the planes proxy. OpenAI
// Responses streams end with one complete usage object; Anthropic Messages
// streams split input (message_start) and output (message_delta) counts, and
// report prompt-cache reads/writes as separate fields.

async function observe(chunks: readonly string[]): Promise<ReturnType<typeof __test.usageFromTail>> {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
  let captured: ReturnType<typeof __test.usageFromTail> | undefined;
  const observed = observeModelUsage(body, (usage) => {
    captured = usage;
  });
  // Drain like a client would; the observer must pass every byte through.
  const drained: Uint8Array[] = [];
  const reader = observed!.getReader();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    drained.push(value);
  }
  expect(drained.length).toBe(chunks.length);
  return captured ?? null;
}

describe("model usage observation", () => {
  test("reads a complete OpenAI Responses usage object from the tail", async () => {
    const usage = await observe([
      'event: response.created\ndata: {"type":"response.created","response":{"model":"gpt-5.2-codex"}}\n\n',
      'event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":100},"output_tokens":30,"total_tokens":150}}}\n\n',
    ]);
    expect(usage).toEqual({
      model: "gpt-5.2-codex",
      inputTokens: 120,
      cachedInputTokens: 100,
      cacheCreationInputTokens: 0,
      outputTokens: 30,
      totalTokens: 150,
    });
  });

  test("merges Anthropic message_start and message_delta usage across a stream", async () => {
    const usage = await observe([
      'event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":12,"cache_creation_input_tokens":2000,"cache_read_input_tokens":8000,"output_tokens":1}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":450}}\n\n',
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    ]);
    expect(usage).toEqual({
      model: "claude-sonnet-5",
      inputTokens: 12,
      cachedInputTokens: 8000,
      cacheCreationInputTokens: 2000,
      outputTokens: 450,
      totalTokens: 462,
    });
  });

  test("reads a non-streaming Anthropic response's single usage object", () => {
    const usage = __test.usageFromTail(
      '{"model":"claude-sonnet-5","usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":40,"output_tokens":9}}',
      "claude-sonnet-5",
    );
    expect(usage).toEqual({
      model: "claude-sonnet-5",
      inputTokens: 50,
      cachedInputTokens: 40,
      cacheCreationInputTokens: 0,
      outputTokens: 9,
      totalTokens: 59,
    });
  });

  test("reports a provider stream that fails mid-response and propagates the error", async () => {
    const failure = new Error("upstream reset");
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('data: {"model":"claude-sonnet-5"}\n\n'));
      },
      pull(controller) {
        controller.error(failure);
      },
    });
    const reported: unknown[] = [];
    let completed = false;
    const observed = observeModelUsage(
      body,
      () => {
        completed = true;
      },
      (error) => reported.push(error),
    );
    const reader = observed!.getReader();
    const first = await reader.read();
    expect(first.done).toBe(false);
    await expect(reader.read()).rejects.toBe(failure);
    expect(reported).toEqual([failure]);
    // A broken stream never yields a usage record.
    expect(completed).toBe(false);
  });

  test("a client hang-up (abort-class error) propagates without being reported", async () => {
    const abort = new DOMException("The operation was aborted.", "AbortError");
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        controller.error(abort);
      },
    });
    const reported: unknown[] = [];
    const observed = observeModelUsage(body, () => {}, (error) => reported.push(error));
    await expect(observed!.getReader().read()).rejects.toBe(abort);
    expect(reported).toEqual([]);
  });

  test("yields nothing when neither side of the stream completes the counts", () => {
    expect(__test.usageFromStream("", '{"usage":{"output_tokens":9}}')).toBeNull();
    expect(__test.usageFromStream('{"usage":{"input_tokens":9}}', "no usage here")).toBeNull();
  });
});
