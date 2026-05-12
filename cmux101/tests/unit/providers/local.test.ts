/**
 * Unit tests for OllamaProvider and LMStudioProvider.
 *
 * Tests cover model-list parsing from realistic server responses and streaming
 * translation behavior.
 */

import { describe, it, expect, mock } from "bun:test";
import {
  OllamaProvider,
  LMStudioProvider,
  OllamaProviderFactory,
  LMStudioProviderFactory,
} from "../../../src/providers/local.js";
import type { ProviderRequest, StreamEvent } from "../../../src/core/types.js";
import { ProviderError } from "../../../src/core/types.js";

// ---------------------------------------------------------------------------
// OllamaProvider.listModels()
// ---------------------------------------------------------------------------

describe("OllamaProvider.listModels()", () => {
  it("parses a realistic /api/tags response", async () => {
    const mockTagsResponse = {
      models: [
        {
          name: "llama3.2:3b",
          modified_at: "2024-01-01T00:00:00Z",
          size: 2000000000,
          details: { family: "llama", parameter_size: "3B" },
        },
        {
          name: "qwen2.5:7b",
          modified_at: "2024-01-01T00:00:00Z",
          size: 4000000000,
          details: { family: "qwen2", parameter_size: "7B" },
        },
        {
          name: "phi3:mini",
          modified_at: "2024-01-01T00:00:00Z",
          size: 2000000000,
          details: { family: "phi3", parameter_size: "3.8B" },
        },
      ],
    };

    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async (url: string) => {
      expect(url).toContain("/api/tags");
      expect(url).not.toContain("/v1/");
      return new Response(JSON.stringify(mockTagsResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider("http://localhost:11434/v1");
      const models = await provider.listModels();

      expect(models).toHaveLength(3);

      const llama = models.find((m) => m.id === "llama3.2:3b");
      expect(llama).toBeDefined();
      expect(llama!.supportsTools).toBe(true); // llama3.x should support tools
      expect(llama!.contextWindow).toBe(32768);
      expect(llama!.maxOutput).toBe(4096);

      const qwen = models.find((m) => m.id === "qwen2.5:7b");
      expect(qwen).toBeDefined();
      expect(qwen!.supportsTools).toBe(true); // qwen2.5 should support tools

      // phi3 is not in the heuristic list
      const phi = models.find((m) => m.id === "phi3:mini");
      expect(phi).toBeDefined();
      expect(phi!.supportsTools).toBe(false);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("calls /api/tags not /v1/models (Ollama-native endpoint)", async () => {
    let requestedUrl = "";
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async (url: string) => {
      requestedUrl = url;
      return new Response(JSON.stringify({ models: [] }), { status: 200 });
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider("http://localhost:11434/v1");
      await provider.listModels();
      expect(requestedUrl).toBe("http://localhost:11434/api/tags");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("throws ProviderError when Ollama is unreachable", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      throw new Error("Connection refused");
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      await expect(provider.listModels()).rejects.toBeInstanceOf(ProviderError);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("throws ProviderError on non-2xx response", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(JSON.stringify({ error: "not found" }), {
        status: 404,
      });
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      await expect(provider.listModels()).rejects.toBeInstanceOf(ProviderError);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("caches results for 60 seconds", async () => {
    let callCount = 0;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      callCount++;
      return new Response(
        JSON.stringify({ models: [{ name: "llama3.1:latest" }] }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      await provider.listModels();
      await provider.listModels();
      await provider.listModels();
      expect(callCount).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

// ---------------------------------------------------------------------------
// LMStudioProvider.listModels()
// ---------------------------------------------------------------------------

describe("LMStudioProvider.listModels()", () => {
  it("parses a realistic /v1/models response", async () => {
    const mockModelsResponse = {
      object: "list",
      data: [
        {
          id: "lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF",
          object: "model",
          owned_by: "lmstudio-community",
          context_window: 131072,
        },
        {
          id: "bartowski/Qwen2.5-7B-Instruct-GGUF",
          object: "model",
          owned_by: "bartowski",
          context_window: 32768,
        },
      ],
    };

    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async (url: string) => {
      expect(url).toContain("/v1/models");
      return new Response(JSON.stringify(mockModelsResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;

    try {
      const provider = new LMStudioProvider("http://localhost:1234/v1");
      const models = await provider.listModels();

      expect(models).toHaveLength(2);

      const llama = models.find((m) =>
        m.id.includes("Meta-Llama-3.1"),
      );
      expect(llama).toBeDefined();
      expect(llama!.contextWindow).toBe(131072);
      expect(llama!.supportsTools).toBe(true); // llama-3.1 matches heuristic

      const qwen = models.find((m) => m.id.includes("Qwen2.5"));
      expect(qwen).toBeDefined();
      expect(qwen!.contextWindow).toBe(32768);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("returns sensible defaults when context_window is absent", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(
        JSON.stringify({
          data: [{ id: "some-obscure-model" }],
        }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new LMStudioProvider();
      const models = await provider.listModels();

      expect(models).toHaveLength(1);
      expect(models[0].contextWindow).toBe(32768); // conservative default
      expect(models[0].maxOutput).toBe(4096);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("throws ProviderError when LM Studio is unreachable", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      throw new Error("Connection refused");
    }) as unknown as typeof fetch;

    try {
      const provider = new LMStudioProvider();
      await expect(provider.listModels()).rejects.toBeInstanceOf(ProviderError);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

// ---------------------------------------------------------------------------
// Streaming translation (shared base logic)
// ---------------------------------------------------------------------------

describe("OllamaProvider.stream() translation", () => {
  async function collectEvents(
    provider: OllamaProvider,
    request: ProviderRequest,
  ): Promise<StreamEvent[]> {
    const events: StreamEvent[] = [];
    for await (const event of provider.stream(request)) {
      events.push(event);
    }
    return events;
  }

  function makeChunkIterable(chunks: object[]): AsyncIterable<object> {
    return {
      [Symbol.asyncIterator]() {
        let i = 0;
        return {
          async next() {
            if (i < chunks.length) return { value: chunks[i++], done: false };
            return { value: undefined, done: true };
          },
        };
      },
    };
  }

  it("emits message_start, text_delta, and message_stop", async () => {
    const chunks = [
      {
        id: "chatcmpl-1",
        choices: [{ index: 0, delta: { role: "assistant", content: "Hi there" }, finish_reason: null }],
        usage: null,
      },
      {
        id: "chatcmpl-1",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
        usage: { prompt_tokens: 5, completion_tokens: 2 },
      },
    ];

    const provider = new OllamaProvider();
    const mockCreate = mock(async () => makeChunkIterable(chunks));
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "llama3.1:latest",
      messages: [{ role: "user", content: [{ type: "text", text: "Hello" }] }],
    };

    const events = await collectEvents(provider, request);

    expect(events[0].kind).toBe("message_start");

    const textDeltas = events.filter((e) => e.kind === "text_delta");
    expect(textDeltas).toHaveLength(1);
    expect((textDeltas[0] as { kind: "text_delta"; text: string }).text).toBe("Hi there");

    const lastEvent = events[events.length - 1];
    expect(lastEvent.kind).toBe("message_stop");
    expect((lastEvent as { kind: "message_stop"; reason: string }).reason).toBe("end_turn");
  });

  it("includes a system message when request.system is provided", async () => {
    const chunks = [
      {
        id: "chatcmpl-2",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
        usage: null,
      },
    ];

    const provider = new OllamaProvider();
    let capturedMessages: unknown[] = [];
    const mockCreate = mock(async (body: { messages: unknown[] }) => {
      capturedMessages = body.messages;
      return makeChunkIterable(chunks);
    });
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "llama3.1:latest",
      messages: [{ role: "user", content: [{ type: "text", text: "Hello" }] }],
      system: "You are a helpful assistant.",
    };

    await collectEvents(provider, request);

    const systemMsg = capturedMessages.find(
      (m: unknown) => (m as { role: string }).role === "system",
    );
    expect(systemMsg).toBeDefined();
    expect((systemMsg as { content: string }).content).toBe("You are a helpful assistant.");
  });

  it("emits tool_call_start and tool_call_end for tool use", async () => {
    const chunks = [
      {
        id: "chatcmpl-3",
        choices: [
          {
            index: 0,
            delta: {
              role: "assistant",
              content: null,
              tool_calls: [
                {
                  index: 0,
                  id: "call_xyz",
                  type: "function",
                  function: { name: "list_files", arguments: '{"dir":"/tmp"}' },
                },
              ],
            },
            finish_reason: "tool_calls",
          },
        ],
        usage: { prompt_tokens: 15, completion_tokens: 10 },
      },
    ];

    const provider = new OllamaProvider();
    const mockCreate = mock(async () => makeChunkIterable(chunks));
    (provider as unknown as { client: { chat: { completions: { create: typeof mockCreate } } } })
      .client.chat.completions.create = mockCreate;

    const request: ProviderRequest = {
      model: "llama3.1:latest",
      messages: [{ role: "user", content: [{ type: "text", text: "List files" }] }],
      tools: [
        {
          name: "list_files",
          description: "List files in a directory",
          inputSchema: { type: "object", properties: { dir: { type: "string" } } },
        },
      ],
    };

    const events = await collectEvents(provider, request);

    const startEvent = events.find((e) => e.kind === "tool_call_start");
    expect(startEvent).toBeDefined();
    expect((startEvent as { kind: "tool_call_start"; name: string }).name).toBe("list_files");

    const endEvent = events.find((e) => e.kind === "tool_call_end");
    expect(endEvent).toBeDefined();
    expect((endEvent as { kind: "tool_call_end"; input: { dir: string } }).input).toEqual({
      dir: "/tmp",
    });

    const stopEvent = events[events.length - 1];
    expect((stopEvent as { kind: "message_stop"; reason: string }).reason).toBe("tool_use");
  });
});

// ---------------------------------------------------------------------------
// supportsTools heuristic
// ---------------------------------------------------------------------------

describe("supportsTools heuristic", () => {
  it("llama3.x models support tools", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(
        JSON.stringify({
          models: [
            { name: "llama3.1:8b" },
            { name: "llama3.2:3b" },
            { name: "llama3:latest" },
          ],
        }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      const models = await provider.listModels();
      expect(models.every((m) => m.supportsTools)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("qwen2.5 models support tools", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(
        JSON.stringify({ models: [{ name: "qwen2.5:7b" }, { name: "qwen2.5-coder:14b" }] }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      const models = await provider.listModels();
      expect(models.every((m) => m.supportsTools)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("mistral models support tools", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(
        JSON.stringify({ models: [{ name: "mistral:7b" }, { name: "mixtral:8x7b" }] }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      const models = await provider.listModels();
      expect(models.every((m) => m.supportsTools)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("old/unknown models do not support tools", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = mock(async () => {
      return new Response(
        JSON.stringify({ models: [{ name: "phi2:latest" }, { name: "orca-mini:latest" }] }),
        { status: 200 },
      );
    }) as unknown as typeof fetch;

    try {
      const provider = new OllamaProvider();
      const models = await provider.listModels();
      expect(models.every((m) => !m.supportsTools)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

// ---------------------------------------------------------------------------
// Factories
// ---------------------------------------------------------------------------

describe("OllamaProviderFactory", () => {
  it("fromEnv always returns a provider (even without env vars)", () => {
    const provider = OllamaProviderFactory.fromEnv({});
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("ollama");
  });

  it("fromEnv uses OLLAMA_BASE_URL when set", () => {
    const provider = OllamaProviderFactory.fromEnv({
      OLLAMA_BASE_URL: "http://my-ollama:11434/v1",
    });
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("ollama");
  });

  it("fromConfig uses provided baseUrl", () => {
    const provider = OllamaProviderFactory.fromConfig({
      baseUrl: "http://remote:11434/v1",
    });
    expect(provider.id).toBe("ollama");
  });

  it("fromConfig uses default URL when baseUrl absent", () => {
    const provider = OllamaProviderFactory.fromConfig({});
    expect(provider.id).toBe("ollama");
  });
});

describe("LMStudioProviderFactory", () => {
  it("fromEnv always returns a provider", () => {
    const provider = LMStudioProviderFactory.fromEnv({});
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("lmstudio");
  });

  it("fromEnv uses LMSTUDIO_BASE_URL when set", () => {
    const provider = LMStudioProviderFactory.fromEnv({
      LMSTUDIO_BASE_URL: "http://my-lmstudio:1234/v1",
    });
    expect(provider).not.toBeNull();
    expect(provider!.id).toBe("lmstudio");
  });

  it("fromConfig uses provided baseUrl", () => {
    const provider = LMStudioProviderFactory.fromConfig({
      baseUrl: "http://custom:1234/v1",
    });
    expect(provider.id).toBe("lmstudio");
  });
});
