/**
 * Unit tests for the Anthropic provider adapter.
 *
 * Tests cover:
 *   1. Message translation (cmux101 Message[] → Anthropic MessageParam[])
 *   2. StreamEvent translation via a fake SDK event helper
 *
 * No real API calls are made.
 */

import { test, expect, describe } from "bun:test";
import type {
  Message,
  StreamEvent,
} from "../../../src/core/types.js";
import { AnthropicProvider, AnthropicProviderFactory } from "../../../src/providers/anthropic.js";
import Anthropic from "@anthropic-ai/sdk";

// ---------------------------------------------------------------------------
// Helpers: re-expose private translation logic by instantiating the class and
// exercising stream() with a fake SDK client.
// ---------------------------------------------------------------------------

/**
 * Build a fake Anthropic SDK client whose messages.stream() returns a
 * controlled sequence of raw SDK events.
 */
function buildFakeClient(
  sdkEvents: Array<Record<string, unknown>>,
): Anthropic {
  // Create an async generator that yields the events
  async function* fakeStream() {
    for (const ev of sdkEvents) {
      yield ev;
    }
  }

  // finalMessage is called after message_stop
  const fakeFinalMessage = async () => ({
    id: "msg_test",
    type: "message",
    role: "assistant",
    content: [],
    model: "claude-sonnet-4-6",
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: 100,
      output_tokens: 50,
      cache_read_input_tokens: 10,
      cache_creation_input_tokens: 5,
    },
  });

  const streamObj = {
    [Symbol.asyncIterator]: fakeStream,
    finalMessage: fakeFinalMessage,
  };

  const fakeMessages = {
    stream: () => streamObj,
  };

  return { messages: fakeMessages } as unknown as Anthropic;
}

/** Collect all StreamEvents from a provider.stream() call into an array. */
async function collectEvents(
  client: Anthropic,
  messages: Message[],
): Promise<StreamEvent[]> {
  const provider = new AnthropicProvider(client);
  const events: StreamEvent[] = [];
  for await (const ev of provider.stream({
    model: "claude-sonnet-4-6",
    messages,
    maxTokens: 1024,
  })) {
    events.push(ev);
  }
  return events;
}

// ---------------------------------------------------------------------------
// 1. Message translation tests
// ---------------------------------------------------------------------------

describe("message translation", () => {
  test("strips system messages from messages array", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          // Return minimal stream that terminates immediately
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x",
              type: "message",
              role: "assistant",
              content: [],
              model: "claude-sonnet-4-6",
              stop_reason: "end_turn",
              stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      { role: "system", content: [{ type: "text", text: "System prompt" }] },
      { role: "user", content: [{ type: "text", text: "Hello" }] },
    ];

    const provider = new AnthropicProvider(client);
    // drain
    for await (const _ of provider.stream({ model: "claude-sonnet-4-6", messages, maxTokens: 512 })) {
      // consume
    }

    expect(capturedParams).not.toBeNull();
    const params = capturedParams!;
    // No system role in messages array
    const msgArray = params.messages as unknown as Array<{ role: string }>;
    expect(msgArray.every((m) => m.role !== "system")).toBe(true);
    // Should be just the user message
    expect(msgArray).toHaveLength(1);
    expect(msgArray[0].role).toBe("user");
  });

  test("passes system string as top-level system param", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      { role: "user", content: [{ type: "text", text: "Hi" }] },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({
      model: "claude-sonnet-4-6",
      messages,
      system: "You are helpful.",
      maxTokens: 512,
    })) {}

    const params = capturedParams!;
    expect(params.system).toBeDefined();
    const sysParts = params.system as Anthropic.TextBlockParam[];
    expect(sysParts[0].text).toBe("You are helpful.");
  });

  test("translates text content blocks", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      {
        role: "user",
        content: [{ type: "text", text: "Tell me a joke" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "Why did the chicken..." }],
      },
      {
        role: "user",
        content: [{ type: "text", text: "Ha! Another one?" }],
      },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({ model: "claude-sonnet-4-6", messages, maxTokens: 512 })) {}

    const params = capturedParams!;
    const msgArr = params.messages as Anthropic.MessageParam[];
    expect(msgArr).toHaveLength(3);
    expect(msgArr[0].role).toBe("user");
    expect(msgArr[1].role).toBe("assistant");
    expect(msgArr[2].role).toBe("user");
  });

  test("translates tool_use block", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "tool_abc",
            name: "search",
            input: { query: "Bun runtime" },
          },
        ],
      },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({ model: "claude-sonnet-4-6", messages, maxTokens: 512 })) {}

    const params = capturedParams!;
    const msgArr = params.messages as Anthropic.MessageParam[];
    expect(msgArr[0].role).toBe("assistant");
    const blk = (msgArr[0].content as Anthropic.ContentBlockParam[])[0] as Anthropic.ToolUseBlockParam;
    expect(blk.type).toBe("tool_use");
    expect(blk.id).toBe("tool_abc");
    expect(blk.name).toBe("search");
    expect((blk.input as Record<string, unknown>)["query"]).toBe("Bun runtime");
  });

  test("translates tool_result block", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      {
        role: "tool",
        content: [
          {
            type: "tool_result",
            tool_use_id: "tool_abc",
            content: "Search results here",
            is_error: false,
          },
        ],
      },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({ model: "claude-sonnet-4-6", messages, maxTokens: 512 })) {}

    const params = capturedParams!;
    const msgArr = params.messages as Anthropic.MessageParam[];
    // tool role maps to user role
    expect(msgArr[0].role).toBe("user");
    const blk = (msgArr[0].content as Anthropic.ContentBlockParam[])[0] as Anthropic.ToolResultBlockParam;
    expect(blk.type).toBe("tool_result");
    expect(blk.tool_use_id).toBe("tool_abc");
    expect(blk.content).toBe("Search results here");
  });

  test("translates image block (base64)", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      {
        role: "user",
        content: [
          {
            type: "image",
            source: { kind: "base64", mediaType: "image/png", data: "abc123" },
          },
        ],
      },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({ model: "claude-sonnet-4-6", messages, maxTokens: 512 })) {}

    const params = capturedParams!;
    const msgArr = params.messages as Anthropic.MessageParam[];
    const blk = (msgArr[0].content as Anthropic.ContentBlockParam[])[0] as Anthropic.ImageBlockParam;
    expect(blk.type).toBe("image");
    expect(blk.source.type).toBe("base64");
    expect((blk.source as Anthropic.Base64ImageSource).data).toBe("abc123");
  });

  test("applies cache_control when >= 3 messages", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    // 3 messages → should apply cache
    const messages: Message[] = [
      { role: "user", content: [{ type: "text", text: "msg1" }] },
      { role: "assistant", content: [{ type: "text", text: "msg2" }] },
      { role: "user", content: [{ type: "text", text: "msg3" }] },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({
      model: "claude-sonnet-4-6",
      messages,
      system: "Sys",
      tools: [{ name: "t", description: "d", inputSchema: { type: "object", properties: {} } }],
      maxTokens: 512,
    })) {}

    const params = capturedParams!;

    // System should have cache_control
    const sysParts = params.system as Array<Anthropic.TextBlockParam & { cache_control?: unknown }>;
    expect(sysParts[0].cache_control).toEqual({ type: "ephemeral" });

    // Last tool should have cache_control
    const tools = params.tools as Array<Anthropic.Tool & { cache_control?: unknown }>;
    expect(tools[tools.length - 1].cache_control).toEqual({ type: "ephemeral" });

    // Last message's last content block should have cache_control
    const msgArr = params.messages as Array<Anthropic.MessageParam>;
    const lastMsg = msgArr[msgArr.length - 1];
    const contentArr = lastMsg.content as unknown as Array<Record<string, unknown>>;
    const lastBlk = contentArr[contentArr.length - 1]!;
    expect(lastBlk["cache_control"]).toEqual({ type: "ephemeral" });
  });

  test("does NOT apply cache_control when < 3 messages", async () => {
    let capturedParams: Anthropic.MessageStreamParams | null = null;

    const client = {
      messages: {
        stream: (params: Anthropic.MessageStreamParams) => {
          capturedParams = params;
          async function* empty() {}
          return {
            [Symbol.asyncIterator]: empty,
            finalMessage: async () => ({
              id: "msg_x", type: "message", role: "assistant", content: [],
              model: "claude-sonnet-4-6", stop_reason: "end_turn", stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            }),
          };
        },
      },
    } as unknown as Anthropic;

    const messages: Message[] = [
      { role: "user", content: [{ type: "text", text: "msg1" }] },
    ];

    const provider = new AnthropicProvider(client);
    for await (const _ of provider.stream({
      model: "claude-sonnet-4-6",
      messages,
      system: "Sys",
      maxTokens: 512,
    })) {}

    const params = capturedParams!;
    const sysParts = params.system as Array<Anthropic.TextBlockParam & { cache_control?: unknown }>;
    expect(sysParts[0].cache_control).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// 2. StreamEvent translation tests
// ---------------------------------------------------------------------------

describe("stream event translation", () => {
  const baseMessages: Message[] = [
    { role: "user", content: [{ type: "text", text: "hi" }] },
  ];

  test("emits message_start from message_start SDK event", async () => {
    const sdkEvents = [
      {
        type: "message_start",
        message: {
          id: "msg_123",
          type: "message",
          role: "assistant",
          content: [],
          model: "claude-sonnet-4-6",
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 10, output_tokens: 0 },
        },
      },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const start = events.find((e) => e.kind === "message_start");
    expect(start).toBeDefined();
    expect((start as { kind: "message_start"; messageId: string }).messageId).toBe("msg_123");
  });

  test("emits text_delta from content_block_delta text_delta", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "text", text: "" },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text: "Hello " },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text: "world" },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const textDeltas = events.filter((e) => e.kind === "text_delta");
    expect(textDeltas).toHaveLength(2);
    expect((textDeltas[0] as { kind: "text_delta"; text: string }).text).toBe("Hello ");
    expect((textDeltas[1] as { kind: "text_delta"; text: string }).text).toBe("world");
  });

  test("emits thinking_delta from content_block_delta thinking_delta", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "thinking", thinking: "" },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "thinking_delta", thinking: "Let me think..." },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const thinkingDeltas = events.filter((e) => e.kind === "thinking_delta");
    expect(thinkingDeltas.length).toBeGreaterThan(0);
    const first = thinkingDeltas[0] as { kind: "thinking_delta"; text: string };
    expect(first.text).toBe("Let me think...");
  });

  test("emits tool_call_start on tool_use content_block_start", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: {
          type: "tool_use",
          id: "toolu_abc",
          name: "read_file",
          input: {},
        },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '{"path":' },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '"/tmp/x"}' },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const start = events.find((e) => e.kind === "tool_call_start") as
      | { kind: "tool_call_start"; id: string; name: string }
      | undefined;
    expect(start).toBeDefined();
    expect(start!.id).toBe("toolu_abc");
    expect(start!.name).toBe("read_file");
  });

  test("emits tool_call_input_delta for input_json_delta", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "tool_use", id: "toolu_abc", name: "fn", input: {} },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '{"k":' },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '"v"}' },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const inputDeltas = events.filter((e) => e.kind === "tool_call_input_delta");
    expect(inputDeltas).toHaveLength(2);
    const d0 = inputDeltas[0] as { kind: "tool_call_input_delta"; id: string; jsonDelta: string };
    expect(d0.id).toBe("toolu_abc");
    expect(d0.jsonDelta).toBe('{"k":');
  });

  test("emits tool_call_end with assembled input on content_block_stop", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "tool_use", id: "toolu_xyz", name: "run", input: {} },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '{"cmd":"ls"}' },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const end = events.find((e) => e.kind === "tool_call_end") as
      | { kind: "tool_call_end"; id: string; input: unknown }
      | undefined;
    expect(end).toBeDefined();
    expect(end!.id).toBe("toolu_xyz");
    expect(end!.input).toEqual({ cmd: "ls" });
  });

  test("tool_call_end with empty input yields {}", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "tool_use", id: "toolu_empty", name: "noop", input: {} },
      },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const end = events.find((e) => e.kind === "tool_call_end") as
      | { kind: "tool_call_end"; id: string; input: unknown }
      | undefined;
    expect(end).toBeDefined();
    expect(end!.input).toEqual({});
  });

  test("emits usage event with final message usage", async () => {
    const sdkEvents = [
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const usageEvts = events.filter((e) => e.kind === "usage");
    expect(usageEvts.length).toBeGreaterThan(0);
    const u = usageEvts[usageEvts.length - 1] as {
      kind: "usage";
      inputTokens: number;
      outputTokens: number;
      cacheReadTokens?: number;
      cacheCreationTokens?: number;
    };
    expect(u.inputTokens).toBe(100);
    expect(u.outputTokens).toBe(50);
    expect(u.cacheReadTokens).toBe(10);
    expect(u.cacheCreationTokens).toBe(5);
  });

  test("emits message_stop with correct stop reason", async () => {
    const sdkEvents = [{ type: "message_stop" }];
    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const stop = events.find((e) => e.kind === "message_stop") as
      | { kind: "message_stop"; reason: string }
      | undefined;
    expect(stop).toBeDefined();
    expect(stop!.reason).toBe("end_turn");
  });

  test("handles multiple tool blocks in parallel", async () => {
    const sdkEvents = [
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "tool_use", id: "tool_0", name: "alpha", input: {} },
      },
      {
        type: "content_block_start",
        index: 1,
        content_block: { type: "tool_use", id: "tool_1", name: "beta", input: {} },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "input_json_delta", partial_json: '{"x":1}' },
      },
      {
        type: "content_block_delta",
        index: 1,
        delta: { type: "input_json_delta", partial_json: '{"y":2}' },
      },
      { type: "content_block_stop", index: 0 },
      { type: "content_block_stop", index: 1 },
      { type: "message_stop" },
    ];

    const client = buildFakeClient(sdkEvents);
    const events = await collectEvents(client, baseMessages);

    const starts = events.filter((e) => e.kind === "tool_call_start");
    const ends = events.filter((e) => e.kind === "tool_call_end");

    expect(starts).toHaveLength(2);
    expect(ends).toHaveLength(2);

    const end0 = ends.find(
      (e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "tool_0"
    ) as { kind: "tool_call_end"; id: string; input: unknown } | undefined;
    const end1 = ends.find(
      (e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "tool_1"
    ) as { kind: "tool_call_end"; id: string; input: unknown } | undefined;

    expect(end0!.input).toEqual({ x: 1 });
    expect(end1!.input).toEqual({ y: 2 });
  });
});

// ---------------------------------------------------------------------------
// 3. Factory tests
// ---------------------------------------------------------------------------

describe("AnthropicProviderFactory", () => {
  test("fromEnv returns null when ANTHROPIC_API_KEY is absent", () => {
    const result = AnthropicProviderFactory.fromEnv({});
    expect(result).toBeNull();
  });

  test("fromEnv returns AnthropicProvider when ANTHROPIC_API_KEY is set", () => {
    const result = AnthropicProviderFactory.fromEnv({ ANTHROPIC_API_KEY: "sk-test" });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("anthropic");
  });

  test("fromConfig returns provider", () => {
    const result = AnthropicProviderFactory.fromConfig({ apiKey: "sk-test" });
    expect(result.id).toBe("anthropic");
  });
});

// ---------------------------------------------------------------------------
// 4. listModels
// ---------------------------------------------------------------------------

describe("listModels", () => {
  test("returns at least Opus 4.7, Sonnet 4.6, Haiku 4.5", async () => {
    const provider = AnthropicProviderFactory.fromEnv({ ANTHROPIC_API_KEY: "sk-test" })!;
    const models = await provider.listModels();

    const ids = models.map((m) => m.id);
    expect(ids).toContain("claude-opus-4-7");
    expect(ids).toContain("claude-sonnet-4-6");
    expect(ids).toContain("claude-haiku-4-5");

    for (const m of models) {
      expect(m.contextWindow).toBeGreaterThan(0);
      expect(m.maxOutput).toBeGreaterThan(0);
    }
  });
});
