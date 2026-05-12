/**
 * Unit tests for the OpenAI provider adapter.
 * No real API calls are made.
 */

import { describe, it, expect } from "bun:test";
import {
  translateMessages,
  mapFinishReason,
  OpenAIProvider,
  OpenAIProviderFactory,
} from "../../../src/providers/openai.js";
import type { Message, StreamEvent } from "../../../src/core/types.js";
import { ProviderError } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// translateMessages – message translation roundtrip
// ---------------------------------------------------------------------------

describe("translateMessages", () => {
  it("translates a system message", () => {
    const msgs: Message[] = [
      { role: "system", content: [{ type: "text", text: "You are helpful." }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "system", content: "You are helpful." }]);
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
          { type: "text", text: "What is this?" },
          {
            type: "image",
            source: { kind: "base64", mediaType: "image/png", data: "abc123" },
          },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          { type: "text", text: "What is this?" },
          { type: "image_url", image_url: { url: "data:image/png;base64,abc123" } },
        ],
      },
    ]);
  });

  it("translates a user message with URL image", () => {
    const msgs: Message[] = [
      {
        role: "user",
        content: [
          {
            type: "image",
            source: { kind: "url", url: "https://example.com/img.png" },
          },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: { url: "https://example.com/img.png" },
          },
        ],
      },
    ]);
  });

  it("translates an assistant text message", () => {
    const msgs: Message[] = [
      { role: "assistant", content: [{ type: "text", text: "Hi there!" }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "assistant", content: "Hi there!" }]);
  });

  it("translates an assistant message with tool_use blocks", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "call_1",
            name: "get_weather",
            input: { city: "NYC" },
          },
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
            function: {
              name: "get_weather",
              arguments: JSON.stringify({ city: "NYC" }),
            },
          },
        ],
      },
    ]);
  });

  it("translates a tool result message", () => {
    const msgs: Message[] = [
      {
        role: "tool",
        content: [
          {
            type: "tool_result",
            tool_use_id: "call_1",
            content: "Sunny and 72°F",
          },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "tool",
        tool_call_id: "call_1",
        content: "Sunny and 72°F",
      },
    ]);
  });

  it("stringifies array content in tool result", () => {
    const msgs: Message[] = [
      {
        role: "tool",
        content: [
          {
            type: "tool_result",
            tool_use_id: "call_2",
            content: [{ type: "text", text: "result text" }],
          },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "tool",
        tool_call_id: "call_2",
        content: JSON.stringify([{ type: "text", text: "result text" }]),
      },
    ]);
  });

  it("silently drops thinking blocks from user messages", () => {
    const msgs: Message[] = [
      {
        role: "user",
        content: [
          { type: "thinking", thinking: "let me think..." },
          { type: "text", text: "Hello" },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "user", content: "Hello" }]);
  });

  it("silently drops thinking blocks from assistant messages", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "reasoning..." },
          { type: "text", text: "Answer" },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "assistant", content: "Answer" }]);
  });

  it("handles multi-turn conversation", () => {
    const msgs: Message[] = [
      { role: "user", content: [{ type: "text", text: "What is 2+2?" }] },
      { role: "assistant", content: [{ type: "text", text: "4" }] },
      { role: "user", content: [{ type: "text", text: "And 3+3?" }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toHaveLength(3);
    expect(out[0]).toEqual({ role: "user", content: "What is 2+2?" });
    expect(out[1]).toEqual({ role: "assistant", content: "4" });
    expect(out[2]).toEqual({ role: "user", content: "And 3+3?" });
  });
});

// ---------------------------------------------------------------------------
// mapFinishReason
// ---------------------------------------------------------------------------

describe("mapFinishReason", () => {
  it("maps stop -> end_turn", () => {
    expect(mapFinishReason("stop")).toBe("end_turn");
  });
  it("maps tool_calls -> tool_use", () => {
    expect(mapFinishReason("tool_calls")).toBe("tool_use");
  });
  it("maps length -> max_tokens", () => {
    expect(mapFinishReason("length")).toBe("max_tokens");
  });
  it("maps content_filter -> refusal", () => {
    expect(mapFinishReason("content_filter")).toBe("refusal");
  });
  it("maps unknown -> end_turn", () => {
    expect(mapFinishReason("unknown_reason")).toBe("end_turn");
  });
  it("maps null -> end_turn", () => {
    expect(mapFinishReason(null)).toBe("end_turn");
  });
  it("maps undefined -> end_turn", () => {
    expect(mapFinishReason(undefined)).toBe("end_turn");
  });
});

// ---------------------------------------------------------------------------
// Tool call accumulator across streaming deltas
// ---------------------------------------------------------------------------

/**
 * Builds a mock OpenAI streaming client that replays the given chunks.
 * Returns an OpenAIProvider wired to use that mock.
 */
function makeMockProvider(chunks: object[]): OpenAIProvider {
  const mockClient = {
    chat: {
      completions: {
        create: async () => {
          async function* gen() {
            for (const c of chunks) yield c;
          }
          return gen();
        },
      },
    },
  } as never;
  return new OpenAIProvider(mockClient);
}

async function collectEvents(provider: OpenAIProvider, request: Parameters<OpenAIProvider["stream"]>[0]): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const evt of provider.stream(request)) {
    events.push(evt);
  }
  return events;
}

describe("stream – text delta", () => {
  it("emits message_start, text_delta, usage, message_stop for simple text", async () => {
    const chunks = [
      {
        id: "chatcmpl-abc",
        choices: [{ delta: { content: "Hello, " }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "chatcmpl-abc",
        choices: [{ delta: { content: "world!" }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "chatcmpl-abc",
        choices: [{ delta: {}, finish_reason: "stop", index: 0 }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Hi" }] }],
    });

    expect(events[0]).toEqual({ kind: "message_start", messageId: "chatcmpl-abc" });
    expect(events[1]).toEqual({ kind: "text_delta", text: "Hello, " });
    expect(events[2]).toEqual({ kind: "text_delta", text: "world!" });
    expect(events[3]).toEqual({ kind: "usage", inputTokens: 10, outputTokens: 5 });
    expect(events[4]).toEqual({ kind: "message_stop", reason: "end_turn" });
  });
});

describe("stream – tool call accumulator across deltas", () => {
  it("accumulates tool call args across multiple delta chunks", async () => {
    // Simulate OpenAI streaming tool_calls across several chunks
    const chunks = [
      {
        id: "chatcmpl-tool",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: "call_abc", type: "function", function: { name: "get_weather", arguments: "" } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tool",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, function: { arguments: '{"city":' } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tool",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, function: { arguments: '"NYC"}' } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tool",
        choices: [{ delta: {}, finish_reason: "tool_calls", index: 0 }],
        usage: { prompt_tokens: 20, completion_tokens: 10 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Weather?" }] }],
    });

    const kindSeq = events.map((e) => e.kind);
    expect(kindSeq[0]).toBe("message_start");
    expect(kindSeq[1]).toBe("tool_call_start");
    expect(kindSeq[2]).toBe("tool_call_input_delta");
    expect(kindSeq[3]).toBe("tool_call_input_delta");
    expect(kindSeq[4]).toBe("usage");
    expect(kindSeq[5]).toBe("tool_call_end");
    expect(kindSeq[6]).toBe("message_stop");

    const start = events[1] as Extract<StreamEvent, { kind: "tool_call_start" }>;
    expect(start.name).toBe("get_weather");
    expect(start.id).toBe("call_abc");

    const end = events[5] as Extract<StreamEvent, { kind: "tool_call_end" }>;
    expect(end.input).toEqual({ city: "NYC" });
    expect(end.id).toBe("call_abc");

    const stop = events[6] as Extract<StreamEvent, { kind: "message_stop" }>;
    expect(stop.reason).toBe("tool_use");
  });

  it("handles two parallel tool calls in one stream", async () => {
    const chunks = [
      {
        id: "chatcmpl-multi",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: "call_0", type: "function", function: { name: "tool_a", arguments: '{"x":1}' } },
                { index: 1, id: "call_1", type: "function", function: { name: "tool_b", arguments: '{"y":2}' } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-multi",
        choices: [{ delta: {}, finish_reason: "tool_calls", index: 0 }],
        usage: { prompt_tokens: 5, completion_tokens: 5 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Go" }] }],
    });

    const starts = events.filter((e) => e.kind === "tool_call_start") as Extract<StreamEvent, { kind: "tool_call_start" }>[];
    const ends = events.filter((e) => e.kind === "tool_call_end") as Extract<StreamEvent, { kind: "tool_call_end" }>[];

    expect(starts).toHaveLength(2);
    expect(ends).toHaveLength(2);

    const names = starts.map((s) => s.name).sort();
    expect(names).toEqual(["tool_a", "tool_b"]);

    const endInputs = ends.map((e) => e.input);
    expect(endInputs).toContainEqual({ x: 1 });
    expect(endInputs).toContainEqual({ y: 2 });
  });
});

// ---------------------------------------------------------------------------
// finish_reason mapping in stream
// ---------------------------------------------------------------------------

describe("stream – finish_reason mapping", () => {
  const reasons = [
    ["stop", "end_turn"],
    ["tool_calls", "tool_use"],
    ["length", "max_tokens"],
    ["content_filter", "refusal"],
  ] as const;

  for (const [oaReason, cmuxReason] of reasons) {
    it(`maps finish_reason "${oaReason}" to "${cmuxReason}"`, async () => {
      const chunks = [
        {
          id: "chatcmpl-x",
          choices: [{ delta: {}, finish_reason: oaReason, index: 0 }],
          usage: null,
        },
      ];
      const provider = makeMockProvider(chunks);
      const events = await collectEvents(provider, {
        model: "gpt-4o",
        messages: [{ role: "user", content: [{ type: "text", text: "test" }] }],
      });
      const stop = events.find((e) => e.kind === "message_stop") as Extract<StreamEvent, { kind: "message_stop" }> | undefined;
      expect(stop?.reason).toBe(cmuxReason);
    });
  }
});

// ---------------------------------------------------------------------------
// OpenAIProviderFactory
// ---------------------------------------------------------------------------

describe("OpenAIProviderFactory", () => {
  it("returns null when OPENAI_API_KEY is absent", () => {
    const factory = new OpenAIProviderFactory();
    const provider = factory.fromEnv({});
    expect(provider).toBeNull();
  });

  it("returns a provider when OPENAI_API_KEY is present", () => {
    const factory = new OpenAIProviderFactory();
    const provider = factory.fromEnv({ OPENAI_API_KEY: "sk-test" });
    expect(provider).toBeInstanceOf(OpenAIProvider);
  });

  it("fromConfig throws without apiKey", () => {
    const factory = new OpenAIProviderFactory();
    expect(() => factory.fromConfig({})).toThrow(ProviderError);
  });

  it("fromConfig returns provider with apiKey", () => {
    const factory = new OpenAIProviderFactory();
    const provider = factory.fromConfig({ apiKey: "sk-test" });
    expect(provider).toBeInstanceOf(OpenAIProvider);
  });
});

// ---------------------------------------------------------------------------
// listModels
// ---------------------------------------------------------------------------

describe("OpenAIProvider.listModels", () => {
  it("returns a non-empty list including gpt-4o and o3-mini", async () => {
    const factory = new OpenAIProviderFactory();
    const provider = factory.fromConfig({ apiKey: "sk-test" })!;
    const models = await provider.listModels();
    expect(models.length).toBeGreaterThan(0);
    const ids = models.map((m) => m.id);
    expect(ids).toContain("gpt-4o");
    expect(ids).toContain("o3-mini");
    expect(ids).toContain("o1");
  });

  it("all models have required fields", async () => {
    const factory = new OpenAIProviderFactory();
    const provider = factory.fromConfig({ apiKey: "sk-test" })!;
    const models = await provider.listModels();
    for (const m of models) {
      expect(typeof m.id).toBe("string");
      expect(typeof m.contextWindow).toBe("number");
      expect(typeof m.maxOutput).toBe("number");
    }
  });
});
