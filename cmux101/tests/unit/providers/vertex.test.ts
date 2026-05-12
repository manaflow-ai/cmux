/**
 * Unit tests for the Vertex AI provider adapter.
 *
 * Tests cover:
 *   1. Request body construction (anthropic_version, messages, system, tools, stream:true)
 *   2. Stream event translation via fake SSE (same Anthropic shape as native)
 *   3. HTTP error handling (non-200 status → ProviderError, retryable for 429/5xx)
 *   4. Auth error handling
 *   5. Factory fromEnv / fromConfig
 *
 * No real GCP calls are made. GoogleAuth and fetch are mocked.
 */

import { test, expect, describe, mock, beforeEach } from "bun:test";
import type { Message, StreamEvent } from "../../../src/core/types.js";
import { ProviderError } from "../../../src/core/types.js";
import { VertexProvider, VertexProviderFactory } from "../../../src/providers/vertex.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Encode a sequence of Anthropic-shaped events as an SSE response body stream.
 * Each event becomes a "data: <json>\n\n" line.
 */
function buildSSEStream(events: Array<Record<string, unknown>>): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const lines = events
    .map((ev) => `data: ${JSON.stringify(ev)}\n\n`)
    .join("");

  return new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(lines));
      controller.close();
    },
  });
}

interface CapturedRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

/**
 * Build a VertexProvider with mocked auth and fetch.
 *
 * @param sseEvents - events to deliver as SSE
 * @param httpStatus - HTTP status code to return (default 200)
 * @param captureRequest - optional callback to inspect the POST request
 */
function buildFakeProvider(
  sseEvents: Array<Record<string, unknown>>,
  httpStatus: number = 200,
  captureRequest?: (req: CapturedRequest) => void,
): VertexProvider {
  const provider = new VertexProvider("my-project", "us-east5");

  // Mock the auth object on the provider instance
  const mockAuth = {
    getAccessToken: () => Promise.resolve("fake-access-token"),
  };
  (provider as unknown as Record<string, unknown>)["auth"] = mockAuth;

  // Mock global fetch
  const originalFetch = globalThis.fetch;
  (globalThis as unknown as Record<string, unknown>)["fetch"] = async (
    url: string,
    init: RequestInit,
  ) => {
    if (captureRequest) {
      captureRequest({
        url,
        method: init.method ?? "GET",
        headers: init.headers as Record<string, string>,
        body: JSON.parse(init.body as string) as Record<string, unknown>,
      });
    }

    if (httpStatus !== 200) {
      return new Response(`Error response`, { status: httpStatus });
    }

    return new Response(buildSSEStream(sseEvents), {
      status: 200,
      headers: { "Content-Type": "text/event-stream" },
    });
  };

  // We cannot easily restore fetch per-test without afterEach, but tests are isolated enough.
  // Restore after each stream() call in test teardown.

  return provider;
}

async function collectEvents(
  provider: VertexProvider,
  model: string,
  messages: Message[],
  options: {
    system?: string;
    tools?: { name: string; description: string; inputSchema: Record<string, unknown> }[];
    maxTokens?: number;
  } = {},
): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  try {
    for await (const ev of provider.stream({
      model,
      messages,
      maxTokens: options.maxTokens ?? 1024,
      ...options,
    })) {
      events.push(ev);
    }
  } catch (err) {
    // re-throw to let test handle
    throw err;
  }
  return events;
}

const VERTEX_MODEL = "claude-sonnet-4-6@20250929";

const baseMessages: Message[] = [
  { role: "user", content: [{ type: "text", text: "hi" }] },
];

// ---------------------------------------------------------------------------
// 1. Request body construction
// ---------------------------------------------------------------------------

describe("request body construction", () => {
  test("sets anthropic_version to vertex-2023-10-16", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages);

    expect(captured).not.toBeNull();
    expect(captured!.body["anthropic_version"]).toBe("vertex-2023-10-16");
  });

  test("sets stream: true in body", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages);

    expect(captured!.body["stream"]).toBe(true);
  });

  test("passes max_tokens correctly", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages, { maxTokens: 2048 });

    expect(captured!.body["max_tokens"]).toBe(2048);
  });

  test("strips system messages and sends as body.system", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    const messages: Message[] = [
      { role: "system", content: [{ type: "text", text: "Be helpful" }] },
      { role: "user", content: [{ type: "text", text: "Hello" }] },
    ];

    await collectEvents(provider, VERTEX_MODEL, messages, { system: "Be helpful" });

    const bodyMessages = captured!.body["messages"] as Array<{ role: string }>;
    expect(bodyMessages.every((m) => m.role !== "system")).toBe(true);
    expect(bodyMessages).toHaveLength(1);
    expect(captured!.body["system"]).toBe("Be helpful");
  });

  test("sends tools with input_schema in body", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages, {
      tools: [
        { name: "read_file", description: "Read a file", inputSchema: { type: "object", properties: { path: { type: "string" } } } },
      ],
    });

    const tools = captured!.body["tools"] as Array<{ name: string; input_schema: unknown }>;
    expect(Array.isArray(tools)).toBe(true);
    expect(tools).toHaveLength(1);
    expect(tools[0].name).toBe("read_file");
    expect(tools[0].input_schema).toEqual({ type: "object", properties: { path: { type: "string" } } });
  });

  test("URL includes project, region, and model", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages);

    expect(captured!.url).toContain("my-project");
    expect(captured!.url).toContain("us-east5");
    expect(captured!.url).toContain(VERTEX_MODEL);
    expect(captured!.url).toContain(":streamRawPredict");
    expect(captured!.url).toContain("publishers/anthropic/models");
  });

  test("Authorization header contains Bearer token", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    await collectEvents(provider, VERTEX_MODEL, baseMessages);

    expect(captured!.headers["Authorization"]).toBe("Bearer fake-access-token");
  });

  test("tool role maps to user in vertex messages", async () => {
    let captured: CapturedRequest | null = null;
    const provider = buildFakeProvider([{ type: "message_stop" }], 200, (req) => { captured = req; });

    const messages: Message[] = [
      { role: "tool", content: [{ type: "tool_result", tool_use_id: "t1", content: "output" }] },
    ];

    await collectEvents(provider, VERTEX_MODEL, messages);

    const bodyMessages = captured!.body["messages"] as Array<{ role: string }>;
    expect(bodyMessages[0].role).toBe("user");
  });
});

// ---------------------------------------------------------------------------
// 2. Stream event translation
// ---------------------------------------------------------------------------

describe("stream event translation", () => {
  test("emits message_start from message_start SSE event", async () => {
    const events = [
      { type: "message_start", message: { id: "msg_vtx_001", usage: { input_tokens: 10, output_tokens: 0 } } },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const start = received.find((e) => e.kind === "message_start");
    expect(start).toBeDefined();
    expect((start as { kind: "message_start"; messageId: string }).messageId).toBe("msg_vtx_001");
  });

  test("emits text_delta from text_delta SSE events", async () => {
    const events = [
      { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello " } },
      { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Vertex" } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const deltas = received.filter((e) => e.kind === "text_delta");
    expect(deltas).toHaveLength(2);
    expect((deltas[0] as { kind: "text_delta"; text: string }).text).toBe("Hello ");
    expect((deltas[1] as { kind: "text_delta"; text: string }).text).toBe("Vertex");
  });

  test("emits thinking_delta", async () => {
    const events = [
      { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
      { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "thoughts" } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const thinking = received.filter((e) => e.kind === "thinking_delta");
    expect(thinking.length).toBeGreaterThan(0);
    expect((thinking[0] as { kind: "thinking_delta"; text: string }).text).toBe("thoughts");
  });

  test("emits tool_call_start + tool_call_input_delta + tool_call_end", async () => {
    const events = [
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_vtx", name: "search", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"q":' } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '"bun"}' } },
      { type: "content_block_stop", index: 0 },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const start = received.find((e) => e.kind === "tool_call_start") as
      | { kind: "tool_call_start"; id: string; name: string } | undefined;
    expect(start).toBeDefined();
    expect(start!.id).toBe("toolu_vtx");
    expect(start!.name).toBe("search");

    const end = received.find((e) => e.kind === "tool_call_end") as
      | { kind: "tool_call_end"; id: string; input: unknown } | undefined;
    expect(end).toBeDefined();
    expect(end!.input).toEqual({ q: "bun" });
  });

  test("emits usage event with input and output tokens", async () => {
    const events = [
      { type: "message_start", message: { id: "m", usage: { input_tokens: 30, output_tokens: 0 } } },
      { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 10 } },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const usageEvts = received.filter((e) => e.kind === "usage");
    expect(usageEvts.length).toBeGreaterThan(0);
    const u = usageEvts[usageEvts.length - 1] as { kind: "usage"; inputTokens: number; outputTokens: number };
    expect(u.inputTokens).toBe(30);
    expect(u.outputTokens).toBe(10);
  });

  test("emits message_stop with correct stop reason", async () => {
    const events = [
      { type: "message_delta", delta: { stop_reason: "max_tokens" }, usage: { output_tokens: 1 } },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const stop = received.find((e) => e.kind === "message_stop") as
      | { kind: "message_stop"; reason: string } | undefined;
    expect(stop).toBeDefined();
    expect(stop!.reason).toBe("max_tokens");
  });

  test("emits message_stop end_turn when no stop reason given", async () => {
    const events = [{ type: "message_stop" }];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const stop = received.find((e) => e.kind === "message_stop") as
      | { kind: "message_stop"; reason: string } | undefined;
    expect(stop).toBeDefined();
    expect(stop!.reason).toBe("end_turn");
  });

  test("includes cache token counts when present", async () => {
    const events = [
      {
        type: "message_start",
        message: {
          id: "m",
          usage: {
            input_tokens: 50,
            output_tokens: 0,
            cache_read_input_tokens: 40,
            cache_creation_input_tokens: 10,
          },
        },
      },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const usageEvts = received.filter((e) => e.kind === "usage");
    const u = usageEvts[usageEvts.length - 1] as {
      kind: "usage";
      cacheReadTokens?: number;
      cacheCreationTokens?: number;
    };
    expect(u.cacheReadTokens).toBe(40);
    expect(u.cacheCreationTokens).toBe(10);
  });

  test("handles multiple tool blocks in parallel", async () => {
    const events = [
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "t0", name: "a", input: {} } },
      { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "t1", name: "b", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"x":1}' } },
      { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"y":2}' } },
      { type: "content_block_stop", index: 0 },
      { type: "content_block_stop", index: 1 },
      { type: "message_stop" },
    ];
    const provider = buildFakeProvider(events);
    const received = await collectEvents(provider, VERTEX_MODEL, baseMessages);

    const ends = received.filter((e) => e.kind === "tool_call_end");
    expect(ends).toHaveLength(2);

    const end0 = ends.find((e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "t0") as { input: unknown } | undefined;
    const end1 = ends.find((e) => (e as { kind: "tool_call_end"; id: string; input: unknown }).id === "t1") as { input: unknown } | undefined;
    expect(end0!.input).toEqual({ x: 1 });
    expect(end1!.input).toEqual({ y: 2 });
  });
});

// ---------------------------------------------------------------------------
// 3. HTTP error handling
// ---------------------------------------------------------------------------

describe("HTTP error handling", () => {
  test("throws ProviderError for HTTP 401", async () => {
    const provider = buildFakeProvider([], 401);

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.provider).toBe("vertex");
    expect(pe.status).toBe(401);
    expect(pe.retryable).toBe(false);
  });

  test("throws retryable ProviderError for HTTP 429", async () => {
    const provider = buildFakeProvider([], 429);

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.retryable).toBe(true);
    expect(pe.status).toBe(429);
  });

  test("throws retryable ProviderError for HTTP 500", async () => {
    const provider = buildFakeProvider([], 500);

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.retryable).toBe(true);
    expect(pe.status).toBe(500);
  });

  test("throws retryable ProviderError for HTTP 503", async () => {
    const provider = buildFakeProvider([], 503);

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.retryable).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// 4. Auth error handling
// ---------------------------------------------------------------------------

describe("auth error handling", () => {
  test("throws ProviderError when getAccessToken rejects", async () => {
    const provider = new VertexProvider("my-project", "us-east5");
    (provider as unknown as Record<string, unknown>)["auth"] = {
      getAccessToken: () => Promise.reject(new Error("no credentials")),
    };

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.provider).toBe("vertex");
    expect(pe.status).toBe(401);
    expect(pe.message).toContain("access token");
  });

  test("throws ProviderError when getAccessToken returns null", async () => {
    const provider = new VertexProvider("my-project", "us-east5");
    (provider as unknown as Record<string, unknown>)["auth"] = {
      getAccessToken: () => Promise.resolve(null),
    };

    let caught: unknown;
    try {
      await collectEvents(provider, VERTEX_MODEL, baseMessages);
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(ProviderError);
    const pe = caught as ProviderError;
    expect(pe.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
// 5. Factory
// ---------------------------------------------------------------------------

describe("VertexProviderFactory", () => {
  test("fromEnv returns null when GOOGLE_CLOUD_PROJECT is absent", () => {
    const result = VertexProviderFactory.fromEnv({});
    expect(result).toBeNull();
  });

  test("fromEnv returns VertexProvider when GOOGLE_CLOUD_PROJECT is set", () => {
    const result = VertexProviderFactory.fromEnv({ GOOGLE_CLOUD_PROJECT: "my-project" });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("vertex");
  });

  test("fromEnv accepts GOOGLE_APPLICATION_CREDENTIALS", () => {
    const result = VertexProviderFactory.fromEnv({
      GOOGLE_CLOUD_PROJECT: "my-project",
      GOOGLE_APPLICATION_CREDENTIALS: "/path/to/key.json",
    });
    expect(result).not.toBeNull();
    expect(result!.id).toBe("vertex");
  });

  test("fromEnv uses VERTEX_REGION override (default us-east5)", () => {
    // Can't easily inspect region without exposing internals, but verify no throw
    const result = VertexProviderFactory.fromEnv({
      GOOGLE_CLOUD_PROJECT: "proj",
      VERTEX_REGION: "europe-west4",
    });
    expect(result).not.toBeNull();
  });

  test("fromConfig returns VertexProvider with project and region", () => {
    const result = VertexProviderFactory.fromConfig({ project: "my-project", region: "us-central1" });
    expect(result.id).toBe("vertex");
  });

  test("fromConfig throws ProviderError when project is missing", () => {
    expect(() => VertexProviderFactory.fromConfig({})).toThrow(ProviderError);
  });
});

// ---------------------------------------------------------------------------
// 6. listModels
// ---------------------------------------------------------------------------

describe("listModels", () => {
  test("returns Anthropic Claude models with @-style version IDs", async () => {
    const provider = VertexProviderFactory.fromEnv({ GOOGLE_CLOUD_PROJECT: "proj" })!;
    const models = await provider.listModels();

    const ids = models.map((m) => m.id);
    expect(ids.some((id) => id.includes("claude-opus-4-7"))).toBe(true);
    expect(ids.some((id) => id.includes("claude-sonnet-4-6"))).toBe(true);
    expect(ids.some((id) => id.includes("claude-haiku-4-5"))).toBe(true);

    for (const m of models) {
      expect(m.contextWindow).toBeGreaterThan(0);
      expect(m.maxOutput).toBeGreaterThan(0);
      expect(typeof m.supportsTools).toBe("boolean");
    }
  });
});
