/**
 * Unit tests for the Bedrock provider adapter.
 *
 * Tests cover:
 *   1. Request body construction (model ID, anthropic_version, messages, system, tools)
 *   2. Stream event translation (same Anthropic Messages API shape as native)
 *   3. Error handling (non-Anthropic model, retryable errors, wrapping)
 *   4. Factory fromEnv / fromConfig
 *
 * No real AWS calls are made.
 */

import { test, expect, describe } from "bun:test";
import type { Message, StreamEvent } from "../../../src/core/types.js";
import { ProviderError } from "../../../src/core/types.js";
import { BedrockProvider, BedrockProviderFactory } from "../../../src/providers/bedrock.js";
import {
  BedrockRuntimeClient,
  InvokeModelWithResponseStreamCommand,
} from "@aws-sdk/client-bedrock-runtime";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Encode an Anthropic-shaped event object into a Bedrock stream chunk.
 * The Bedrock stream yields objects like { chunk: { bytes: Uint8Array } }
 * where bytes is the JSON-encoded event.
 */
function encodeChunk(event: Record<string, unknown>): { chunk: { bytes: Uint8Array } } {
  return {
    chunk: {
      bytes: new TextEncoder().encode(JSON.stringify(event)),
    },
  };
}

/**
 * Build a fake BedrockRuntimeClient that intercepts send() and returns a
 * controlled stream of chunks.
 *
 * @param chunks - sequence of stream event objects to deliver
 * @param captureInput - optional callback to inspect the sent command
 */
function buildFakeClient(
  chunks: Array<Record<string, unknown>>,
  captureInput?: (input: ConstructorParameters<typeof InvokeModelWithResponseStreamCommand>[0]) => void,
): BedrockRuntimeClient {
  async function* fakeStream() {
    for (const chunk of chunks) {
      yield encodeChunk(chunk);
    }
  }

  const fakeClient = {
    send: (command: InvokeModelWithResponseStreamCommand) => {
      // Grab the input for inspection
      if (captureInput) {
        const input = (command as unknown as { input: ConstructorParameters<typeof InvokeModelWithResponseStreamCommand>[0] }).input;
        captureInput(input);
      }
      return Promise.resolve({
        body: {
          [Symbol.asyncIterator]: fakeStream,
        },
        contentType: "application/json",
      });
    },
  };

  return fakeClient as unknown as BedrockRuntimeClient;
}

/** Collect all StreamEvents from a BedrockProvider.stream() call. */
async function collectEvents(
  client: BedrockRuntimeClient,
  model: string,
  messages: Message[],
  options: { system?: string; tools?: { name: string; description: string; inputSchema: Record<string, unknown> }[] } = {},
): Promise<StreamEvent[]> {
  const provider = new BedrockProvider(client);
  const events: StreamEvent[] = [];
  for await (const ev of provider.stream({
    model,
    messages,
    maxTokens: 1024,
    ...options,
  })) {
    events.push(ev);
  }
  return events;
}

const ANTHROPIC_MODEL = "anthropic.claude-sonnet-4-6-20250929-v1:0";

const baseMessages: Message[] = [
  { role: "user", content: [{ type: "text", text: "hi" }] },
];

// ---------------------------------------------------------------------------
// 1. Request body construction
// ---------------------------------------------------------------------------

describe("request body construction", () => {
  test("sets anthropic_version to bedrock-2023-05-31", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        if (input.body) {
          capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
        }
      },
    );

    await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    expect(capturedBody).not.toBeNull();
    expect(capturedBody!["anthropic_version"]).toBe("bedrock-2023-05-31");
  });

  test("passes max_tokens correctly", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    const provider = new BedrockProvider(client);
    for await (const _ of provider.stream({ model: ANTHROPIC_MODEL, messages: baseMessages, maxTokens: 4096 })) {}

    expect(capturedBody!["max_tokens"]).toBe(4096);
  });

  test("strips system messages from messages array and sends as body.system", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    const messages: Message[] = [
      { role: "system", content: [{ type: "text", text: "You are helpful" }] },
      { role: "user", content: [{ type: "text", text: "Hello" }] },
    ];

    await collectEvents(client, ANTHROPIC_MODEL, messages, { system: "You are helpful" });

    const bodyMessages = capturedBody!["messages"] as Array<{ role: string }>;
    expect(bodyMessages.every((m) => m.role !== "system")).toBe(true);
    expect(bodyMessages).toHaveLength(1);
    expect(bodyMessages[0].role).toBe("user");
    expect(capturedBody!["system"]).toBe("You are helpful");
  });

  test("sends tools array in body when tools provided", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    await collectEvents(client, ANTHROPIC_MODEL, baseMessages, {
      tools: [
        { name: "search", description: "Search the web", inputSchema: { type: "object", properties: { query: { type: "string" } } } },
      ],
    });

    expect(Array.isArray(capturedBody!["tools"])).toBe(true);
    const tools = capturedBody!["tools"] as Array<{ name: string; description: string; input_schema: unknown }>;
    expect(tools).toHaveLength(1);
    expect(tools[0].name).toBe("search");
    expect(tools[0].description).toBe("Search the web");
    expect(tools[0].input_schema).toEqual({ type: "object", properties: { query: { type: "string" } } });
  });

  test("does not include tools key when no tools provided", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    await collectEvents(client, ANTHROPIC_MODEL, baseMessages);
    expect(capturedBody!["tools"]).toBeUndefined();
  });

  test("passes temperature and top_p when provided", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    const provider = new BedrockProvider(client);
    for await (const _ of provider.stream({
      model: ANTHROPIC_MODEL,
      messages: baseMessages,
      maxTokens: 1024,
      temperature: 0.7,
      topP: 0.9,
    })) {}

    expect(capturedBody!["temperature"]).toBe(0.7);
    expect(capturedBody!["top_p"]).toBe(0.9);
  });

  test("tool role maps to user in bedrock messages", async () => {
    let capturedBody: Record<string, unknown> | null = null;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedBody = JSON.parse(new TextDecoder().decode(input.body as Uint8Array)) as Record<string, unknown>;
      },
    );

    const messages: Message[] = [
      {
        role: "tool",
        content: [{ type: "tool_result", tool_use_id: "toolu_abc", content: "result text" }],
      },
    ];

    await collectEvents(client, ANTHROPIC_MODEL, messages);

    const bodyMessages = capturedBody!["messages"] as Array<{ role: string }>;
    expect(bodyMessages[0].role).toBe("user");
  });

  test("modelId is passed as-is to InvokeModelWithResponseStreamCommand", async () => {
    let capturedModelId: string | undefined;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedModelId = input.modelId;
      },
    );

    await collectEvents(client, ANTHROPIC_MODEL, baseMessages);
    expect(capturedModelId).toBe(ANTHROPIC_MODEL);
  });

  test("contentType is application/json", async () => {
    let capturedContentType: string | undefined;

    const client = buildFakeClient(
      [{ type: "message_stop" }],
      (input) => {
        capturedContentType = input.contentType;
      },
    );

    await collectEvents(client, ANTHROPIC_MODEL, baseMessages);
    expect(capturedContentType).toBe("application/json");
  });
});

// ---------------------------------------------------------------------------
// 2. Stream event translation
// ---------------------------------------------------------------------------

describe("stream event translation", () => {
  test("emits message_start from message_start event", async () => {
    const chunks = [
      {
        type: "message_start",
        message: {
          id: "msg_bedrock_001",
          usage: { input_tokens: 20, output_tokens: 0 },
        },
      },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const start = events.find((e) => e.kind === "message_start");
    expect(start).toBeDefined();
    expect((start as { kind: "message_start"; messageId: string }).messageId).toBe("msg_bedrock_001");
  });

  test("emits text_delta from content_block_delta text_delta", async () => {
    const chunks = [
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello " } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Bedrock" } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const deltas = events.filter((e) => e.kind === "text_delta");
    expect(deltas).toHaveLength(2);
    expect((deltas[0] as { kind: "text_delta"; text: string }).text).toBe("Hello ");
    expect((deltas[1] as { kind: "text_delta"; text: string }).text).toBe("Bedrock");
  });

  test("emits thinking_delta from thinking_delta event", async () => {
    const chunks = [
      { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "reasoning..." } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const thinking = events.filter((e) => e.kind === "thinking_delta");
    expect(thinking.length).toBeGreaterThan(0);
    expect((thinking[0] as { kind: "thinking_delta"; text: string }).text).toBe("reasoning...");
  });

  test("emits tool_call_start + tool_call_input_delta + tool_call_end", async () => {
    const chunks = [
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_bed", name: "list_files", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"dir":' } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '"/tmp"}' } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const start = events.find((e) => e.kind === "tool_call_start") as
      | { kind: "tool_call_start"; id: string; name: string }
      | undefined;
    expect(start).toBeDefined();
    expect(start!.id).toBe("toolu_bed");
    expect(start!.name).toBe("list_files");

    const inputDeltas = events.filter((e) => e.kind === "tool_call_input_delta");
    expect(inputDeltas).toHaveLength(2);

    const end = events.find((e) => e.kind === "tool_call_end") as
      | { kind: "tool_call_end"; id: string; input: unknown }
      | undefined;
    expect(end).toBeDefined();
    expect(end!.id).toBe("toolu_bed");
    expect(end!.input).toEqual({ dir: "/tmp" });
  });

  test("emits usage with input and output token counts", async () => {
    const chunks = [
      {
        type: "message_start",
        message: {
          id: "msg_tok",
          usage: { input_tokens: 42, output_tokens: 0 },
        },
      },
      { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 17 } },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const usageEvts = events.filter((e) => e.kind === "usage");
    expect(usageEvts.length).toBeGreaterThan(0);
    const u = usageEvts[usageEvts.length - 1] as {
      kind: "usage";
      inputTokens: number;
      outputTokens: number;
    };
    expect(u.inputTokens).toBe(42);
    expect(u.outputTokens).toBe(17);
  });

  test("emits message_stop with correct stop reason from message_delta", async () => {
    const chunks = [
      { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 5 } },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const stop = events.find((e) => e.kind === "message_stop") as
      | { kind: "message_stop"; reason: string }
      | undefined;
    expect(stop).toBeDefined();
    expect(stop!.reason).toBe("tool_use");
  });

  test("emits message_stop with end_turn when no stop reason given", async () => {
    const chunks = [{ type: "message_stop" }];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const stop = events.find((e) => e.kind === "message_stop") as
      | { kind: "message_stop"; reason: string }
      | undefined;
    expect(stop).toBeDefined();
    expect(stop!.reason).toBe("end_turn");
  });

  test("handles multiple tool blocks in parallel", async () => {
    const chunks = [
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "t0", name: "alpha", input: {} } },
      { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "t1", name: "beta", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"x":1}' } },
      { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"y":2}' } },
      { type: "content_block_stop", index: 0 },
      { type: "content_block_stop", index: 1 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const ends = events.filter((e) => e.kind === "tool_call_end");
    expect(ends).toHaveLength(2);

    const end0 = ends.find((e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "t0") as { id: string; input: unknown } | undefined;
    const end1 = ends.find((e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "t1") as { id: string; input: unknown } | undefined;

    expect(end0!.input).toEqual({ x: 1 });
    expect(end1!.input).toEqual({ y: 2 });
  });

  test("includes cache token counts when present in message_start", async () => {
    const chunks = [
      {
        type: "message_start",
        message: {
          id: "msg_cache",
          usage: {
            input_tokens: 100,
            output_tokens: 0,
            cache_read_input_tokens: 80,
            cache_creation_input_tokens: 20,
          },
        },
      },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(chunks);
    const events = await collectEvents(client, ANTHROPIC_MODEL, baseMessages);

    const usageEvts = events.filter((e) => e.kind === "usage");
    const u = usageEvts[usageEvts.length - 1] as {
      kind: "usage";
      cacheReadTokens?: number;
      cacheCreationTokens?: number;
    };
    expect(u.cacheReadTokens).toBe(80);
    expect(u.cacheCreationTokens).toBe(20);
  });

  test("skips malformed/non-JSON chunks gracefully", async () => {
    // Inject a non-JSON chunk (we do this by constructing the raw stream manually)
    async function* fakeStream() {
      yield { chunk: { bytes: new TextEncoder().encode("not-json") } };
      yield encodeChunk({ type: "message_stop" });
    }

    const fakeClient = {
      send: () =>
        Promise.resolve({
          body: { [Symbol.asyncIterator]: fakeStream },
          contentType: "application/json",
        }),
    } as unknown as BedrockRuntimeClient;

    const provider = new BedrockProvider(fakeClient);
    const events: StreamEvent[] = [];
    for await (const ev of provider.stream({ model: ANTHROPIC_MODEL, messages: baseMessages, maxTokens: 1024 })) {
      events.push(ev);
    }

    // Should still emit message_stop and not crash
    const stop = events.find((e) => e.kind === "message_stop");
    expect(stop).toBeDefined();
  });
});

// ---------------------------------------------------------------------------
// 3. Error handling
// ---------------------------------------------------------------------------

describe("error handling", () => {
  test("throws ProviderError for non-Anthropic model IDs", async () => {
    const client = buildFakeClient([]);
    const provider = new BedrockProvider(client);

    let caught: unknown;
    try {
      for await (const _ of provider.stream({ model: "meta.llama3-70b-instruct-v1:0", messages: baseMessages, maxTokens: 1024 })) {}
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.provider).toBe("bedrock");
    expect(pe.status).toBe(400);
    expect(pe.retryable).toBe(false);
    expect(pe.message).toContain("anthropic.");
  });

  test("wraps ThrottlingException as retryable ProviderError with status 429", async () => {
    const throttlingError = new Error("Rate limit exceeded");
    throttlingError.name = "ThrottlingException";

    const fakeClient = {
      send: () => Promise.reject(throttlingError),
    } as unknown as BedrockRuntimeClient;

    const provider = new BedrockProvider(fakeClient);
    const events: StreamEvent[] = [];
    for await (const ev of provider.stream({ model: ANTHROPIC_MODEL, messages: baseMessages, maxTokens: 1024 })) {
      events.push(ev);
    }

    const errorEvt = events.find((e) => e.kind === "error") as
      | { kind: "error"; error: ProviderError }
      | undefined;
    expect(errorEvt).toBeDefined();
    expect(errorEvt!.error.retryable).toBe(true);
    expect(errorEvt!.error.status).toBe(429);
    expect(errorEvt!.error.provider).toBe("bedrock");
  });

  test("wraps InternalServerException as retryable ProviderError with status 500", async () => {
    const serverError = new Error("Internal error");
    serverError.name = "InternalServerException";

    const fakeClient = {
      send: () => Promise.reject(serverError),
    } as unknown as BedrockRuntimeClient;

    const provider = new BedrockProvider(fakeClient);
    const events: StreamEvent[] = [];
    for await (const ev of provider.stream({ model: ANTHROPIC_MODEL, messages: baseMessages, maxTokens: 1024 })) {
      events.push(ev);
    }

    const errorEvt = events.find((e) => e.kind === "error") as
      | { kind: "error"; error: ProviderError }
      | undefined;
    expect(errorEvt).toBeDefined();
    expect(errorEvt!.error.retryable).toBe(true);
    expect(errorEvt!.error.status).toBe(500);
  });

  test("wraps unknown error as non-retryable ProviderError", async () => {
    const fakeClient = {
      send: () => Promise.reject(new Error("unknown network error")),
    } as unknown as BedrockRuntimeClient;

    const provider = new BedrockProvider(fakeClient);
    const events: StreamEvent[] = [];
    for await (const ev of provider.stream({ model: ANTHROPIC_MODEL, messages: baseMessages, maxTokens: 1024 })) {
      events.push(ev);
    }

    const errorEvt = events.find((e) => e.kind === "error") as
      | { kind: "error"; error: ProviderError }
      | undefined;
    expect(errorEvt).toBeDefined();
    expect(errorEvt!.error.retryable).toBe(false);
    expect(errorEvt!.error.provider).toBe("bedrock");
  });
});

// ---------------------------------------------------------------------------
// 4. Factory
// ---------------------------------------------------------------------------

describe("BedrockProviderFactory", () => {
  test("fromEnv returns null when no AWS env vars set", () => {
    const result = BedrockProviderFactory.fromEnv({});
    expect(result).toBeNull();
  });

  test("fromEnv returns provider when AWS_REGION is set", () => {
    const result = BedrockProviderFactory.fromEnv({ AWS_REGION: "us-east-1" });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("bedrock");
  });

  test("fromEnv returns provider when AWS_ACCESS_KEY_ID is set (no region)", () => {
    const result = BedrockProviderFactory.fromEnv({ AWS_ACCESS_KEY_ID: "AKIA..." });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("bedrock");
  });

  test("fromEnv returns provider when AWS_PROFILE is set", () => {
    const result = BedrockProviderFactory.fromEnv({ AWS_PROFILE: "my-profile" });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("bedrock");
  });

  test("fromEnv uses BEDROCK_REGION override over AWS_REGION", () => {
    // We can't easily inspect the client region without exposing internals,
    // but we verify fromEnv doesn't throw and returns a provider
    const result = BedrockProviderFactory.fromEnv({
      AWS_REGION: "us-east-1",
      BEDROCK_REGION: "eu-west-1",
    });
    expect(result).not.toBeNull();
  });

  test("fromConfig returns a BedrockProvider", () => {
    const result = BedrockProviderFactory.fromConfig({ region: "ap-southeast-1" });
    expect(result.id).toBe("bedrock");
  });
});

// ---------------------------------------------------------------------------
// 5. listModels
// ---------------------------------------------------------------------------

describe("listModels", () => {
  test("returns Anthropic Claude models with bedrock-style IDs", async () => {
    const result = BedrockProviderFactory.fromEnv({ AWS_REGION: "us-east-1" })!;
    const models = await result.listModels();

    const ids = models.map((m) => m.id);
    // All IDs should start with "anthropic."
    for (const id of ids) {
      expect(id.startsWith("anthropic.")).toBe(true);
    }

    expect(ids.some((id) => id.includes("claude-opus-4-7"))).toBe(true);
    expect(ids.some((id) => id.includes("claude-sonnet-4-6"))).toBe(true);

    for (const m of models) {
      expect(m.contextWindow).toBeGreaterThan(0);
      expect(m.maxOutput).toBeGreaterThan(0);
      expect(typeof m.supportsTools).toBe("boolean");
    }
  });
});
