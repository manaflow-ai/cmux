/**
 * Unit tests for OpenRouterProvider.
 *
 * These tests exercise the model-list parser and the stream translation logic
 * using mocked fetch / OpenAI SDK responses.
 */

import { describe, it, expect, beforeEach, mock } from "bun:test";
import { OpenRouterProvider, OpenRouterProviderFactory } from "../../../src/providers/openrouter.js";
import type { ModelInfo, StreamEvent, ProviderRequest } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// listModels() — response parsing
// ---------------------------------------------------------------------------

describe("OpenRouterProvider.listModels()", () => {
  it("maps a realistic /models response to ModelInfo[]", async () => {
    const mockResponse = {
      data: [
        {
          id: "anthropic/claude-opus-4.7",
          name: "Claude Opus 4.7",
          context_length: 200000,
          top_provider: { max_completion_tokens: 4096 },
          architecture: { modality: "text" },
          supported_parameters: ["tools", "temperature"],
        },
        {
          id: "openai/gpt-4o",
          name: "GPT-4o",
          context_length: 128000,
          top_provider: { max_completion_tokens: 4096 },
          architecture: { modality: "image+text" },
          supported_parameters: ["tools"],
        },
        {
          id: "google/gemini-2.5-pro",
          name: "Gemini 2.5 Pro",
          context_length: 1000000,
          top_provider: { max_completion_tokens: 8192 },
          architecture: { modality: "multimodal" },
          supported_parameters: ["tools"],
        },
      ],
    };

    // Intercept fetch
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async (_url: string) => {
      return new Response(JSON.stringify(mockResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;

    try {
      const provider = new OpenRouterProvider("test-api-key");
      const models = await provider.listModels();

      expect(models).toHaveLength(3);

      const claude = models.find((m) => m.id === "anthropic/claude-opus-4.7");
      expect(claude).toBeDefined();
      expect(claude!.displayName).toBe("Claude Opus 4.7");
      expect(claude!.contextWindow).toBe(200000);
      expect(claude!.maxOutput).toBe(4096);
      expect(claude!.supportsTools).toBe(true);
      expect(claude!.supportsVision).toBe(false);

      const gpt4o = models.find((m) => m.id === "openai/gpt-4o");
      expect(gpt4o).toBeDefined();
      expect(gpt4o!.supportsVision).toBe(true); // modality contains "image"

      const gemini = models.find((m) => m.id === "google/gemini-2.5-pro");
      expect(gemini).toBeDefined();
      expect(gemini!.supportsVision).toBe(true); // modality is "multimodal"
      expect(gemini!.maxOutput).toBe(8192);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("returns fallback models when the API call fails", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      throw new Error("Network error");
    }) as unknown as typeof fetch;

    try {
      const provider = new OpenRouterProvider("test-api-key");
      const models = await provider.listModels();

      expect(models.length).toBeGreaterThan(0);
      expect(models.some((m) => m.id === "anthropic/claude-opus-4.7")).toBe(true);
      expect(models.some((m) => m.id === "openai/gpt-4o")).toBe(true);
      expect(models.some((m) => m.id === "google/gemini-2.5-pro")).toBe(true);
      expect(models.some((m) => m.id === "meta-llama/llama-3.1-405b")).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("returns fallback models when the API returns a non-2xx status", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
      });
    }) as unknown as typeof fetch;

    try {
      const provider = new OpenRouterProvider("bad-key");
      const models = await provider.listModels();

      // Should fall back gracefully
      expect(models.length).toBeGreaterThan(0);
      expect(models.some((m) => m.id === "anthropic/claude-opus-4.7")).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("caches results for 10 minutes", async () => {
    let callCount = 0;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      callCount++;
      return new Response(
        JSON.stringify({ data: [{ id: "model/a", name: "Model A", context_length: 4096 }] }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OpenRouterProvider("test-key");
      await provider.listModels();
      await provider.listModels();
      await provider.listModels();

      expect(callCount).toBe(1); // Only one real call; rest are cached
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

// ---------------------------------------------------------------------------
// stream() — translation
// ---------------------------------------------------------------------------

describe("OpenRouterProvider.stream() translation", () => {
  /**
   * Helper: collect all events from the stream into an array.
   */
  async function collectEvents(
    provider: OpenRouterProvider,
    request: ProviderRequest,
  ): Promise<StreamEvent[]> {
    const events: StreamEvent[] = [];
    for await (const event of provider.stream(request)) {
      events.push(event);
    }
    return events;
  }

  /**
   * Build a mock OpenAI streaming iterable from a list of chunk objects.
   */
  function makeChunkIterable(
    chunks: object[],
  ): AsyncIterable<object> {
    return {
      [Symbol.asyncIterator]() {
        let i = 0;
        return {
          async next() {
            if (i < chunks.length) {
              return { value: chunks[i++], done: false };
            }
            return { value: undefined, done: true };
          },
        };
      },
    };
  }

  it("emits message_start, text_delta, usage, and message_stop for a simple text response", async () => {
    const chunks = [
      {
        id: "chatcmpl-test",
        choices: [{ index: 0, delta: { role: "assistant", content: "Hello" }, finish_reason: null }],
        usage: null,
      },
      {
        id: "chatcmpl-test",
        choices: [{ index: 0, delta: { content: " world" }, finish_reason: null }],
        usage: null,
      },
      {
        id: "chatcmpl-test",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
        usage: { prompt_tokens: 10, completion_tokens: 2 },
      },
    ];

    const provider = new OpenRouterProvider("test-key");
    // Directly inject mock into the client's chat.completions.create
    const mockCreate = mock(async () => makeChunkIterable(chunks));
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "openai/gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Hi" }] }],
    };

    const events = await collectEvents(provider, request);

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

  it("emits tool_call_start, tool_call_input_delta, and tool_call_end for tool calls", async () => {
    const chunks = [
      {
        id: "chatcmpl-tools",
        choices: [
          {
            index: 0,
            delta: {
              role: "assistant",
              content: null,
              tool_calls: [
                {
                  index: 0,
                  id: "call_abc123",
                  type: "function",
                  function: { name: "read_file", arguments: "" },
                },
              ],
            },
            finish_reason: null,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tools",
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  function: { arguments: '{"path":' },
                },
              ],
            },
            finish_reason: null,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tools",
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  function: { arguments: '"/etc/hosts"}' },
                },
              ],
            },
            finish_reason: null,
          },
        ],
        usage: null,
      },
      {
        id: "chatcmpl-tools",
        choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
        usage: { prompt_tokens: 20, completion_tokens: 15 },
      },
    ];

    const provider = new OpenRouterProvider("test-key");
    const mockCreate = mock(async () => makeChunkIterable(chunks));
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "openai/gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Read a file" }] }],
      tools: [
        {
          name: "read_file",
          description: "Read a file",
          inputSchema: { type: "object", properties: { path: { type: "string" } } },
        },
      ],
    };

    const events = await collectEvents(provider, request);

    const startEvent = events.find((e) => e.kind === "tool_call_start");
    expect(startEvent).toBeDefined();
    expect((startEvent as { kind: "tool_call_start"; id: string; name: string }).id).toBe("call_abc123");
    expect((startEvent as { kind: "tool_call_start"; id: string; name: string }).name).toBe("read_file");

    const inputDeltas = events.filter((e) => e.kind === "tool_call_input_delta");
    expect(inputDeltas.length).toBeGreaterThan(0);

    const endEvent = events.find((e) => e.kind === "tool_call_end");
    expect(endEvent).toBeDefined();
    expect((endEvent as { kind: "tool_call_end"; id: string; input: unknown }).id).toBe("call_abc123");
    expect((endEvent as { kind: "tool_call_end"; id: string; input: { path: string } }).input).toEqual({
      path: "/etc/hosts",
    });

    const stopEvent = events[events.length - 1];
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("tool_use");
  });

  it("maps finish_reason=length to max_tokens StopReason", async () => {
    const chunks = [
      {
        id: "chatcmpl-trunc",
        choices: [{ index: 0, delta: { content: "truncated" }, finish_reason: "length" }],
        usage: { prompt_tokens: 5, completion_tokens: 100 },
      },
    ];

    const provider = new OpenRouterProvider("test-key");
    const mockCreate = mock(async () => makeChunkIterable(chunks));
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "openai/gpt-4o",
      messages: [{ role: "user", content: [{ type: "text", text: "Tell me everything" }] }],
    };

    const events = await collectEvents(provider, request);
    const stopEvent = events.find((e) => e.kind === "message_stop");
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("max_tokens");
  });
});

// ---------------------------------------------------------------------------
// OpenRouterProviderFactory
// ---------------------------------------------------------------------------

describe("OpenRouterProviderFactory", () => {
  it("fromEnv returns null when OPENROUTER_API_KEY is missing", () => {
    const provider = OpenRouterProviderFactory.fromEnv({});
    expect(provider).toBeNull();
  });

  it("fromEnv returns a provider when OPENROUTER_API_KEY is set", () => {
    const provider = OpenRouterProviderFactory.fromEnv({
      OPENROUTER_API_KEY: "or-test-key",
    });
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("openrouter");
  });

  it("fromConfig constructs a provider with the given apiKey", () => {
    const provider = OpenRouterProviderFactory.fromConfig({ apiKey: "or-test-key" });
    expect(provider.id).toBe("openrouter");
  });

  it("fromConfig throws when apiKey is missing", () => {
    expect(() => OpenRouterProviderFactory.fromConfig({})).toThrow();
  });
});
