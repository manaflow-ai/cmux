/**
 * Unit tests for XAIProvider (xAI / Grok).
 * No real API calls are made.
 */

import { describe, it, expect, mock } from "bun:test";
import { XAIProvider, XAIProviderFactory, translateMessages } from "../../../src/providers/xai.js";
import type { Message, StreamEvent, ProviderRequest } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Message translation roundtrip
// ---------------------------------------------------------------------------

describe("translateMessages (xAI)", () => {
  it("translates a system message", () => {
    const msgs: Message[] = [
      { role: "system", content: [{ type: "text", text: "You are Grok." }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "system", content: "You are Grok." }]);
  });

  it("translates a user text message", () => {
    const msgs: Message[] = [
      { role: "user", content: [{ type: "text", text: "Hello!" }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "user", content: "Hello!" }]);
  });

  it("translates a user message with base64 image", () => {
    const msgs: Message[] = [
      {
        role: "user",
        content: [
          { type: "text", text: "Describe this image" },
          { type: "image", source: { kind: "base64", mediaType: "image/png", data: "abc" } },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          { type: "text", text: "Describe this image" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc" } },
        ],
      },
    ]);
  });

  it("translates an assistant message with tool_use", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          { type: "tool_use", id: "call_1", name: "search", input: { q: "grok" } },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: "call_1",
            type: "function",
            function: { name: "search", arguments: JSON.stringify({ q: "grok" }) },
          },
        ],
      },
    ]);
  });

  it("translates a tool result message", () => {
    const msgs: Message[] = [
      {
        role: "tool",
        content: [{ type: "tool_result", tool_use_id: "call_1", content: "result text" }],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      { role: "tool", tool_call_id: "call_1", content: "result text" },
    ]);
  });

  it("silently drops thinking blocks", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "let me think" },
          { type: "text", text: "Answer" },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "assistant", content: "Answer" }]);
  });
});

// ---------------------------------------------------------------------------
// listModels
// ---------------------------------------------------------------------------

describe("XAIProvider.listModels()", () => {
  it("returns grok-3, grok-3-mini, grok-2", async () => {
    const provider = new XAIProvider("test-key");
    const models = await provider.listModels();
    const ids = models.map((m) => m.id);
    expect(ids).toContain("grok-3");
    expect(ids).toContain("grok-3-mini");
    expect(ids).toContain("grok-2");
  });

  it("grok-3 has correct context window and tool/vision support", async () => {
    const provider = new XAIProvider("test-key");
    const models = await provider.listModels();
    const grok3 = models.find((m) => m.id === "grok-3");
    expect(grok3).toBeDefined();
    expect(grok3!.contextWindow).toBe(131_072);
    expect(grok3!.maxOutput).toBe(64_000);
    expect(grok3!.supportsTools).toBe(true);
    expect(grok3!.supportsVision).toBe(true);
  });

  it("grok-3-mini supports tools but not vision", async () => {
    const provider = new XAIProvider("test-key");
    const models = await provider.listModels();
    const mini = models.find((m) => m.id === "grok-3-mini");
    expect(mini!.supportsTools).toBe(true);
    expect(mini!.supportsVision).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Stream translation
// ---------------------------------------------------------------------------

function makeMockProvider(chunks: object[]): XAIProvider {
  const provider = new XAIProvider("test-key");
  const mockCreate = mock(async () => {
    async function* gen() {
      for (const c of chunks) yield c;
    }
    return gen();
  });
  (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
    .client.chat.completions.create = mockCreate;
  return provider;
}

async function collectEvents(provider: XAIProvider, request: ProviderRequest): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const evt of provider.stream(request)) {
    events.push(evt);
  }
  return events;
}

describe("XAIProvider.stream() translation", () => {
  it("emits message_start, text_delta, usage, message_stop for a text response", async () => {
    const chunks = [
      {
        id: "xai-1",
        choices: [{ delta: { content: "Hello" }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "xai-1",
        choices: [{ delta: { content: " world" }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "xai-1",
        choices: [{ delta: {}, finish_reason: "stop", index: 0 }],
        usage: { prompt_tokens: 10, completion_tokens: 2 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "grok-3",
      messages: [{ role: "user", content: [{ type: "text", text: "Hi" }] }],
    });

    expect(events[0].kind).toBe("message_start");
    const textDeltas = events.filter((e) => e.kind === "text_delta");
    expect(textDeltas).toHaveLength(2);
    expect((textDeltas[0] as { kind: "text_delta"; text: string }).text).toBe("Hello");
    expect((textDeltas[1] as { kind: "text_delta"; text: string }).text).toBe(" world");

    const usageEvent = events.find((e) => e.kind === "usage");
    expect(usageEvent).toBeDefined();
    expect((usageEvent as { kind: "usage"; inputTokens: number }).inputTokens).toBe(10);

    const stopEvent = events[events.length - 1];
    expect(stopEvent.kind).toBe("message_stop");
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("end_turn");
  });

  it("emits tool_call_start, tool_call_input_delta, tool_call_end for tool calls", async () => {
    const chunks = [
      {
        id: "xai-2",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: "call_x1", type: "function", function: { name: "read_file", arguments: "" } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "xai-2",
        choices: [
          {
            delta: {
              tool_calls: [{ index: 0, function: { arguments: '{"path":"/etc/hosts"}' } }],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "xai-2",
        choices: [{ delta: {}, finish_reason: "tool_calls", index: 0 }],
        usage: { prompt_tokens: 20, completion_tokens: 10 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "grok-3",
      messages: [{ role: "user", content: [{ type: "text", text: "Read a file" }] }],
      tools: [
        {
          name: "read_file",
          description: "Read a file",
          inputSchema: { type: "object", properties: { path: { type: "string" } } },
        },
      ],
    });

    const startEvent = events.find((e) => e.kind === "tool_call_start");
    expect(startEvent).toBeDefined();
    expect((startEvent as { kind: "tool_call_start"; id: string; name: string }).name).toBe("read_file");

    const endEvent = events.find((e) => e.kind === "tool_call_end");
    expect(endEvent).toBeDefined();
    expect((endEvent as { kind: "tool_call_end"; id: string; input: { path: string } }).input).toEqual({
      path: "/etc/hosts",
    });

    const stopEvent = events[events.length - 1];
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("tool_use");
  });

  it("maps finish_reason=length to max_tokens", async () => {
    const chunks = [
      {
        id: "xai-3",
        choices: [{ delta: { content: "truncated" }, finish_reason: "length", index: 0 }],
        usage: null,
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "grok-3",
      messages: [{ role: "user", content: [{ type: "text", text: "Go" }] }],
    });

    const stopEvent = events.find((e) => e.kind === "message_stop");
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("max_tokens");
  });
});

// ---------------------------------------------------------------------------
// XAIProviderFactory
// ---------------------------------------------------------------------------

describe("XAIProviderFactory", () => {
  it("fromEnv returns null when XAI_API_KEY is missing", () => {
    const provider = XAIProviderFactory.fromEnv({});
    expect(provider).toBeNull();
  });

  it("fromEnv returns a provider when XAI_API_KEY is set", () => {
    const provider = XAIProviderFactory.fromEnv({ XAI_API_KEY: "xai-test-key" });
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("xai");
  });

  it("fromConfig constructs a provider with the given apiKey", () => {
    const provider = XAIProviderFactory.fromConfig({ apiKey: "xai-test-key" });
    expect(provider.id).toBe("xai");
  });

  it("fromConfig throws when apiKey is missing", () => {
    expect(() => XAIProviderFactory.fromConfig({})).toThrow();
  });
});
