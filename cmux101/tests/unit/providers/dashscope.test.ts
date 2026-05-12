/**
 * Unit tests for DashScopeProvider (Alibaba Qwen).
 * No real API calls are made.
 */

import { describe, it, expect, mock } from "bun:test";
import {
  DashScopeProvider,
  DashScopeProviderFactory,
  translateMessages,
  isReasoningModel,
} from "../../../src/providers/dashscope.js";
import type { Message, StreamEvent, ProviderRequest } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// Message translation roundtrip
// ---------------------------------------------------------------------------

describe("translateMessages (DashScope)", () => {
  it("translates a system message", () => {
    const msgs: Message[] = [
      { role: "system", content: [{ type: "text", text: "You are Qwen." }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "system", content: "You are Qwen." }]);
  });

  it("translates a user text message", () => {
    const msgs: Message[] = [
      { role: "user", content: [{ type: "text", text: "Hello!" }] },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "user", content: "Hello!" }]);
  });

  it("translates a user message with URL image", () => {
    const msgs: Message[] = [
      {
        role: "user",
        content: [
          { type: "image", source: { kind: "url", url: "https://example.com/img.png" } },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      {
        role: "user",
        content: [
          { type: "image_url", image_url: { url: "https://example.com/img.png" } },
        ],
      },
    ]);
  });

  it("translates an assistant message with tool_use", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          { type: "tool_use", id: "call_q1", name: "code_exec", input: { code: "print(1)" } },
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
            id: "call_q1",
            type: "function",
            function: { name: "code_exec", arguments: JSON.stringify({ code: "print(1)" }) },
          },
        ],
      },
    ]);
  });

  it("translates a tool result message", () => {
    const msgs: Message[] = [
      {
        role: "tool",
        content: [{ type: "tool_result", tool_use_id: "call_q1", content: "output text" }],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([
      { role: "tool", tool_call_id: "call_q1", content: "output text" },
    ]);
  });

  it("silently drops thinking blocks", () => {
    const msgs: Message[] = [
      {
        role: "assistant",
        content: [
          { type: "thinking", thinking: "reasoning..." },
          { type: "text", text: "Result" },
        ],
      },
    ];
    const out = translateMessages(msgs);
    expect(out).toEqual([{ role: "assistant", content: "Result" }]);
  });
});

// ---------------------------------------------------------------------------
// listModels
// ---------------------------------------------------------------------------

describe("DashScopeProvider.listModels()", () => {
  it("returns expected Qwen models", async () => {
    const provider = new DashScopeProvider("test-key");
    const models = await provider.listModels();
    const ids = models.map((m) => m.id);
    expect(ids).toContain("qwen-max");
    expect(ids).toContain("qwen-plus");
    expect(ids).toContain("qwen-turbo");
    expect(ids).toContain("qwen-coder-plus");
    expect(ids).toContain("qwen3-coder");
    expect(ids).toContain("qwq-32b-preview");
  });

  it("all models have required fields", async () => {
    const provider = new DashScopeProvider("test-key");
    const models = await provider.listModels();
    for (const m of models) {
      expect(typeof m.id).toBe("string");
      expect(typeof m.contextWindow).toBe("number");
      expect(typeof m.maxOutput).toBe("number");
      expect(typeof m.supportsTools).toBe("boolean");
    }
  });
});

// ---------------------------------------------------------------------------
// isReasoningModel helper
// ---------------------------------------------------------------------------

describe("isReasoningModel", () => {
  it("returns true for qwq-* models", () => {
    expect(isReasoningModel("qwq-32b-preview")).toBe(true);
    expect(isReasoningModel("qwq-plus")).toBe(true);
  });

  it("returns true for qwen-qwq-* models", () => {
    expect(isReasoningModel("qwen-qwq-32b")).toBe(true);
  });

  it("returns true for models containing -thinking", () => {
    expect(isReasoningModel("qwen-thinking-v1")).toBe(true);
    expect(isReasoningModel("qwen3-coder-thinking")).toBe(true);
  });

  it("returns false for regular models", () => {
    expect(isReasoningModel("qwen-max")).toBe(false);
    expect(isReasoningModel("qwen-turbo")).toBe(false);
    expect(isReasoningModel("qwen3-coder")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Stream translation
// ---------------------------------------------------------------------------

function makeMockProvider(chunks: object[]): DashScopeProvider {
  const provider = new DashScopeProvider("test-key");
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

async function collectEvents(
  provider: DashScopeProvider,
  request: ProviderRequest,
): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  for await (const evt of provider.stream(request)) {
    events.push(evt);
  }
  return events;
}

describe("DashScopeProvider.stream() translation", () => {
  it("emits message_start, text_delta, usage, message_stop for a text response", async () => {
    const chunks = [
      {
        id: "ds-1",
        choices: [{ delta: { content: "Hello" }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "ds-1",
        choices: [{ delta: { content: " world" }, finish_reason: null, index: 0 }],
        usage: null,
      },
      {
        id: "ds-1",
        choices: [{ delta: {}, finish_reason: "stop", index: 0 }],
        usage: { prompt_tokens: 10, completion_tokens: 2 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "qwen-plus",
      messages: [{ role: "user", content: [{ type: "text", text: "Hi" }] }],
    });

    expect(events[0].kind).toBe("message_start");
    const textDeltas = events.filter((e) => e.kind === "text_delta");
    expect(textDeltas).toHaveLength(2);

    const usageEvent = events.find((e) => e.kind === "usage");
    expect(usageEvent).toBeDefined();
    expect((usageEvent as { kind: "usage"; inputTokens: number }).inputTokens).toBe(10);

    const stopEvent = events[events.length - 1];
    expect(stopEvent.kind).toBe("message_stop");
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("end_turn");
  });

  it("emits tool_call events for tool-use responses", async () => {
    const chunks = [
      {
        id: "ds-2",
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: "call_q1", type: "function", function: { name: "get_weather", arguments: '{"city":"Beijing"}' } },
              ],
            },
            finish_reason: null,
            index: 0,
          },
        ],
        usage: null,
      },
      {
        id: "ds-2",
        choices: [{ delta: {}, finish_reason: "tool_calls", index: 0 }],
        usage: { prompt_tokens: 15, completion_tokens: 8 },
      },
    ];

    const provider = makeMockProvider(chunks);
    const events = await collectEvents(provider, {
      model: "qwen-max",
      messages: [{ role: "user", content: [{ type: "text", text: "Weather?" }] }],
    });

    const startEvent = events.find((e) => e.kind === "tool_call_start");
    expect(startEvent).toBeDefined();
    expect((startEvent as { kind: "tool_call_start"; name: string }).name).toBe("get_weather");

    const endEvent = events.find((e) => e.kind === "tool_call_end");
    expect(endEvent).toBeDefined();
    expect((endEvent as { kind: "tool_call_end"; input: { city: string } }).input).toEqual({ city: "Beijing" });

    const stopEvent = events[events.length - 1];
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("tool_use");
  });
});

// ---------------------------------------------------------------------------
// Reasoning model strips temperature/top_p
// ---------------------------------------------------------------------------

describe("DashScopeProvider — reasoning models strip temperature/top_p", () => {
  it("does NOT include temperature or top_p when model is qwq-32b-preview", async () => {
    let capturedParams: Record<string, unknown> | null = null;

    const provider = new DashScopeProvider("test-key");
    const mockCreate = mock(async (params: Record<string, unknown>) => {
      capturedParams = params;
      async function* gen() {
        yield {
          id: "ds-r1",
          choices: [{ delta: { content: "answer" }, finish_reason: "stop", index: 0 }],
          usage: { prompt_tokens: 5, completion_tokens: 1 },
        };
      }
      return gen();
    });
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const events: StreamEvent[] = [];
    for await (const evt of provider.stream({
      model: "qwq-32b-preview",
      messages: [{ role: "user", content: [{ type: "text", text: "Think" }] }],
      temperature: 0.7,
      topP: 0.9,
    })) {
      events.push(evt);
    }

    expect(capturedParams).not.toBeNull();
    expect(capturedParams!["temperature"]).toBeUndefined();
    expect(capturedParams!["top_p"]).toBeUndefined();
  });

  it("DOES include temperature and top_p for non-reasoning models", async () => {
    let capturedParams: Record<string, unknown> | null = null;

    const provider = new DashScopeProvider("test-key");
    const mockCreate = mock(async (params: Record<string, unknown>) => {
      capturedParams = params;
      async function* gen() {
        yield {
          id: "ds-r2",
          choices: [{ delta: { content: "ok" }, finish_reason: "stop", index: 0 }],
          usage: { prompt_tokens: 5, completion_tokens: 1 },
        };
      }
      return gen();
    });
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const events: StreamEvent[] = [];
    for await (const evt of provider.stream({
      model: "qwen-plus",
      messages: [{ role: "user", content: [{ type: "text", text: "Go" }] }],
      temperature: 0.7,
      topP: 0.9,
    })) {
      events.push(evt);
    }

    expect(capturedParams).not.toBeNull();
    expect(capturedParams!["temperature"]).toBe(0.7);
    expect(capturedParams!["top_p"]).toBe(0.9);
  });

  it("strips temperature/top_p for qwen-thinking variant", async () => {
    let capturedParams: Record<string, unknown> | null = null;

    const provider = new DashScopeProvider("test-key");
    const mockCreate = mock(async (params: Record<string, unknown>) => {
      capturedParams = params;
      async function* gen() {
        yield {
          id: "ds-r3",
          choices: [{ delta: { content: "ok" }, finish_reason: "stop", index: 0 }],
          usage: { prompt_tokens: 5, completion_tokens: 1 },
        };
      }
      return gen();
    });
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    for await (const _ of provider.stream({
      model: "qwen3-coder-thinking",
      messages: [{ role: "user", content: [{ type: "text", text: "Go" }] }],
      temperature: 0.5,
      topP: 0.8,
    })) {
      // consume
    }

    expect(capturedParams!["temperature"]).toBeUndefined();
    expect(capturedParams!["top_p"]).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// DashScopeProviderFactory
// ---------------------------------------------------------------------------

describe("DashScopeProviderFactory", () => {
  it("fromEnv returns null when DASHSCOPE_API_KEY is missing", () => {
    const provider = DashScopeProviderFactory.fromEnv({});
    expect(provider).toBeNull();
  });

  it("fromEnv returns a provider when DASHSCOPE_API_KEY is set", () => {
    const provider = DashScopeProviderFactory.fromEnv({ DASHSCOPE_API_KEY: "ds-test-key" });
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("dashscope");
  });

  it("fromConfig constructs a provider with the given apiKey", () => {
    const provider = DashScopeProviderFactory.fromConfig({ apiKey: "ds-test-key" });
    expect(provider.id).toBe("dashscope");
  });

  it("fromConfig throws when apiKey is missing", () => {
    expect(() => DashScopeProviderFactory.fromConfig({})).toThrow();
  });
});
