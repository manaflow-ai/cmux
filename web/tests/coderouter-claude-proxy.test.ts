import { beforeEach, describe, expect, test } from "bun:test";
import { createHash, createHmac } from "node:crypto";
import { SignatureV4 } from "@smithy/signature-v4";
import {
  createClaudeCountTokensProxy,
  createClaudeMessagesProxy,
  createClaudeModelsProxy,
  type ClaudeProxyDependencies,
} from "../services/coderouter/claudeProxy";
import type { ClaudeUpstream } from "../services/coderouter/claudeUpstream";
import type { RouteTokenAuthResult } from "../services/coderouter/routeTokenAuth";
import {
  bedrockInvokeBody,
  bedrockModelId,
  decodeAwsEventStream,
  encodeAwsEventStreamMessage,
} from "../services/coderouter/bedrock";
import { usageFromText } from "../services/coderouter/claudeUsage";
import { signAwsRequest } from "../services/coderouter/awsSigV4";

type FetchCall = { url: string; init: RequestInit & { duplex?: string } };

let fetchCalls: FetchCall[] = [];
let upstreamResponse: () => Response = () => new Response("{}");
let authResult: RouteTokenAuthResult = ok();
let upstream: ClaudeUpstream | null = null;
let events: { event: string; teamId?: string; properties?: Record<string, unknown> }[] = [];

function ok(vmId: string | null = "vm-1"): RouteTokenAuthResult {
  return {
    ok: true,
    identity: { teamId: "team-1", stackUserId: "user-1", vmId, token: "crt_x" },
  };
}

const dependencies: ClaudeProxyDependencies = {
  authenticate: async () => authResult,
  upstream: async () => upstream,
  fetch: (async (input: string | URL | Request, init?: RequestInit) => {
    fetchCalls.push({ url: String(input), init: (init ?? {}) as FetchCall["init"] });
    return upstreamResponse();
  }) as typeof fetch,
  now: () => new Date("2026-09-02T10:00:00.000Z"),
  capture: (input) => {
    events.push({
      event: input.event,
      ...(input.teamId ? { teamId: input.teamId } : {}),
      ...(input.properties ? { properties: { ...input.properties } } : {}),
    });
  },
};

const messages = createClaudeMessagesProxy(dependencies);
const countTokens = createClaudeCountTokensProxy(dependencies);
const models = createClaudeModelsProxy(dependencies);

const apiKeyUpstream: ClaudeUpstream = {
  teamId: "team-1",
  kind: "anthropic_api_key",
  secret: { kind: "anthropic_api_key", apiKey: "sk-ant-api03-real-secret-key-value-1234" },
  config: {},
  updatedAt: new Date(0),
};
const oauthUpstream: ClaudeUpstream = {
  teamId: "team-1",
  kind: "anthropic_oauth",
  secret: { kind: "anthropic_oauth", token: "sk-ant-oat01-long-lived-oauth-token-value" },
  config: {},
  updatedAt: new Date(0),
};
const bedrockUpstream: ClaudeUpstream = {
  teamId: "team-1",
  kind: "bedrock",
  secret: {
    kind: "bedrock",
    accessKeyId: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    sessionToken: "FwoGZXIvYXdzEBYaDExampleSessionToken",
  },
  config: { region: "us-east-1" },
  updatedAt: new Date(0),
};

function messagesRequest(
  body: Record<string, unknown> = { model: "claude-sonnet-4-5", max_tokens: 8, messages: [] },
  headers: Record<string, string> = {},
): Request {
  return new Request("https://coderouter.dev/v1/messages", {
    method: "POST",
    headers: {
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
      "x-api-key": "cmux-vm-edge-placeholder",
      authorization: "Bearer cmux-vm-edge-placeholder",
      "x-coderouter-route-token": "crt_" + "a".repeat(43),
      "x-cmux-vm-id": "vm-1",
      "user-agent": "claude-cli/2.0.0 (external, cli)",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

function sseStream(events: readonly { type: string; data: Record<string, unknown> }[]): string {
  return events
    .map(({ type, data }) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`)
    .join("");
}

const streamFixture = sseStream([
  {
    type: "message_start",
    data: {
      message: {
        id: "msg_1",
        model: "claude-sonnet-4-5-20250929",
        usage: {
          input_tokens: 10,
          cache_creation_input_tokens: 5,
          cache_read_input_tokens: 100,
          output_tokens: 1,
        },
      },
    },
  },
  { type: "content_block_delta", data: { index: 0, delta: { type: "text_delta", text: "hi" } } },
  { type: "message_delta", data: { delta: { stop_reason: "end_turn" }, usage: { output_tokens: 42 } } },
  { type: "message_stop", data: {} },
]);

async function requestBodyText(call: FetchCall): Promise<string> {
  const body = call.init.body;
  if (body instanceof ReadableStream) return await new Response(body).text();
  if (typeof body === "string") return body;
  if (body instanceof Uint8Array) return Buffer.from(body).toString("utf8");
  throw new Error("unexpected body type");
}

function requestHeaders(call: FetchCall): Headers {
  return new Headers(call.init.headers);
}

beforeEach(() => {
  fetchCalls = [];
  events = [];
  authResult = ok();
  upstream = apiKeyUpstream;
  upstreamResponse = () =>
    new Response(streamFixture, {
      status: 200,
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "request-id": "req_abc",
        "anthropic-ratelimit-requests-remaining": "99",
        "set-cookie": "leak=1",
      },
    });
});

describe("claude proxy auth", () => {
  test("rejects a missing route token in the Anthropic error shape", async () => {
    authResult = { ok: false, reason: "missing_route_token" };
    const response = await messages(messagesRequest());
    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body).toMatchObject({ type: "error", error: { type: "authentication_error" } });
    expect(body.error.message).toContain("route token");
    expect(fetchCalls).toHaveLength(0);
    expect(events.map((event) => event.event)).toEqual([
      "coderouter_auth_rejected",
      "coderouter_route_health",
    ]);
    expect(events[0]?.properties).toEqual({ surface: "messages", reason: "missing_route_token" });
    expect(events[1]?.properties).toMatchObject({
      provider: "claude",
      agent: "claude",
      outcome: "unauthorized",
      failure_stage: "auth",
    });
  });

  test("rejects an invalid token and a VM mismatch", async () => {
    authResult = { ok: false, reason: "invalid_route_token" };
    expect((await messages(messagesRequest())).status).toBe(401);
    authResult = { ok: false, reason: "vm_mismatch" };
    const response = await messages(messagesRequest());
    expect(response.status).toBe(401);
    expect((await response.json()).error.message).toContain("different Cloud VM");
  });

  test("returns 503 when the team has no Claude upstream", async () => {
    upstream = null;
    const response = await messages(messagesRequest());
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      type: "error",
      error: {
        type: "api_error",
        message: "No Claude upstream is configured for this team. Set one at coderouter.dev.",
      },
    });
    expect(events.at(-1)?.properties).toMatchObject({
      outcome: "provider_unavailable",
      failure_stage: "provider_config",
    });
  });
});

describe("claude proxy direct Anthropic upstreams", () => {
  test("forwards with the team API key and strips guest credentials", async () => {
    const response = await messages(
      messagesRequest(undefined, { "anthropic-beta": "interleaved-thinking-2025-05-14", "x-app": "cli" }),
    );
    expect(response.status).toBe(200);
    expect(fetchCalls).toHaveLength(1);
    const call = fetchCalls[0]!;
    expect(call.url).toBe("https://api.anthropic.com/v1/messages");
    expect(call.init.method).toBe("POST");
    expect(call.init.duplex).toBe("half");
    const headers = requestHeaders(call);
    expect(headers.get("x-api-key")).toBe(apiKeyUpstream.secret.kind === "anthropic_api_key" ? apiKeyUpstream.secret.apiKey : "");
    expect(headers.get("authorization")).toBeNull();
    expect(headers.get("x-coderouter-route-token")).toBeNull();
    expect(headers.get("x-cmux-vm-id")).toBeNull();
    expect(headers.get("x-app")).toBeNull();
    expect(headers.get("anthropic-version")).toBe("2023-06-01");
    expect(headers.get("anthropic-beta")).toBe("interleaved-thinking-2025-05-14");
    expect(headers.get("content-type")).toBe("application/json");
    expect(headers.get("user-agent")).toContain("claude-cli");
    expect(JSON.parse(await requestBodyText(call))).toMatchObject({ model: "claude-sonnet-4-5" });

    expect(response.headers.get("content-type")).toBe("text/event-stream; charset=utf-8");
    expect(response.headers.get("request-id")).toBe("req_abc");
    expect(response.headers.get("anthropic-ratelimit-requests-remaining")).toBe("99");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).toBe(streamFixture);
  });

  test("captures usage from the pass-through stream without buffering it", async () => {
    const response = await messages(messagesRequest());
    await response.text();
    const usage = events.find((event) => event.event === "coderouter_model_request_completed");
    expect(usage).toEqual({
      event: "coderouter_model_request_completed",
      teamId: "team-1",
      properties: {
        provider: "claude",
        upstream_kind: "anthropic_api_key",
        model: "claude-sonnet-4-5-20250929",
        input_tokens: 115,
        cached_input_tokens: 100,
        output_tokens: 42,
        total_tokens: 157,
        vm_id: "vm-1",
      },
    });
    const health = events.find((event) => event.event === "coderouter_route_health");
    expect(health?.properties).toMatchObject({
      provider: "claude",
      outcome: "success",
      failure_stage: "none",
      status: 200,
      response_streamed: true,
      vm_id: "vm-1",
    });
  });

  test("omits vm_id for an unbound CLI token", async () => {
    authResult = ok(null);
    const response = await messages(messagesRequest());
    await response.text();
    const usage = events.find((event) => event.event === "coderouter_model_request_completed");
    expect(usage?.properties).not.toHaveProperty("vm_id");
  });

  test("uses a bearer OAuth token and adds the oauth beta flag", async () => {
    upstream = oauthUpstream;
    await messages(
      messagesRequest(undefined, { "anthropic-beta": "interleaved-thinking-2025-05-14", "x-app": "cli" }),
    );
    const headers = requestHeaders(fetchCalls[0]!);
    expect(headers.get("authorization")).toBe("Bearer sk-ant-oat01-long-lived-oauth-token-value");
    expect(headers.get("x-api-key")).toBeNull();
    expect(headers.get("x-coderouter-route-token")).toBeNull();
    expect(headers.get("x-cmux-vm-id")).toBeNull();
    expect(headers.get("anthropic-beta")).toBe("interleaved-thinking-2025-05-14,oauth-2025-04-20");
    expect(headers.get("x-app")).toBe("cli");
    expect(headers.get("host")).toBeNull();
  });

  test("keeps an oauth beta flag the client already sent", async () => {
    upstream = oauthUpstream;
    await messages(messagesRequest(undefined, { "anthropic-beta": "oauth-2025-04-20" }));
    expect(requestHeaders(fetchCalls[0]!).get("anthropic-beta")).toBe("oauth-2025-04-20");
  });

  test("passes upstream errors through unchanged", async () => {
    upstreamResponse = () =>
      Response.json(
        { type: "error", error: { type: "overloaded_error", message: "Overloaded" } },
        { status: 529, headers: { "retry-after": "3" } },
      );
    const response = await messages(messagesRequest());
    expect(response.status).toBe(529);
    expect(response.headers.get("retry-after")).toBe("3");
    expect((await response.json()).error.type).toBe("overloaded_error");
    expect(events.at(-1)?.properties).toMatchObject({ outcome: "upstream_error", status: 529 });
  });

  test("count_tokens and models forward to the matching Anthropic paths", async () => {
    upstreamResponse = () => Response.json({ input_tokens: 12 });
    const counted = await countTokens(
      new Request("https://coderouter.dev/v1/messages/count_tokens", {
        method: "POST",
        headers: { "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: "{}",
      }),
    );
    expect(await counted.json()).toEqual({ input_tokens: 12 });
    expect(fetchCalls[0]?.url).toBe("https://api.anthropic.com/v1/messages/count_tokens");

    upstreamResponse = () => Response.json({ data: [], has_more: false });
    const listed = await models(
      new Request("https://coderouter.dev/v1/models?limit=5", {
        headers: { "anthropic-version": "2023-06-01" },
      }),
    );
    expect(listed.status).toBe(200);
    expect(fetchCalls[1]?.url).toBe("https://api.anthropic.com/v1/models?limit=5");
    expect(fetchCalls[1]?.init.method).toBe("GET");
    expect(fetchCalls[1]?.init.body).toBeUndefined();
  });
});

describe("claude proxy Bedrock upstream", () => {
  beforeEach(() => {
    upstream = bedrockUpstream;
  });

  test("rewrites the body, maps the model, and signs with SigV4", async () => {
    upstreamResponse = () =>
      Response.json(
        {
          id: "msg_b",
          type: "message",
          model: "anthropic.claude-sonnet-4-5-20250929-v1:0",
          content: [],
          usage: { input_tokens: 3, output_tokens: 4 },
        },
        { headers: { "x-amzn-requestid": "aws-req-1" } },
      );
    const response = await messages(
      messagesRequest({ model: "claude-sonnet-4-5", max_tokens: 8, messages: [], stream: false }),
    );
    expect(response.status).toBe(200);
    const call = fetchCalls[0]!;
    expect(call.url).toBe(
      "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-sonnet-4-5-20250929-v1%3A0/invoke",
    );
    const body = JSON.parse(await requestBodyText(call));
    expect(body).toEqual({ max_tokens: 8, messages: [], anthropic_version: "bedrock-2023-05-31" });
    const headers = requestHeaders(call);
    expect(headers.get("x-amz-date")).toBe("20260902T100000Z");
    expect(headers.get("x-amz-security-token")).toBe("FwoGZXIvYXdzEBYaDExampleSessionToken");
    expect(headers.get("authorization")).toMatch(
      /^AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE\/20260902\/us-east-1\/bedrock\/aws4_request, SignedHeaders=accept;content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=[0-9a-f]{64}$/,
    );
    expect(headers.get("x-api-key")).toBeNull();
    expect(headers.get("x-coderouter-route-token")).toBeNull();
    const json = await response.json();
    expect(json.model).toBe("claude-sonnet-4-5");
    expect(response.headers.get("request-id")).toBe("aws-req-1");
    const usage = events.find((event) => event.event === "coderouter_model_request_completed");
    expect(usage?.properties).toMatchObject({
      upstream_kind: "bedrock",
      model: "claude-sonnet-4-5",
      input_tokens: 3,
      output_tokens: 4,
    });
  });

  test("converts the AWS event stream into Anthropic SSE", async () => {
    const chunk = (event: Record<string, unknown>) =>
      encodeAwsEventStreamMessage(
        { ":message-type": "event", ":event-type": "chunk", ":content-type": "application/json" },
        new TextEncoder().encode(JSON.stringify({
          bytes: Buffer.from(JSON.stringify(event)).toString("base64"),
        })),
      );
    const frames = [
      chunk({
        type: "message_start",
        message: {
          id: "msg_s",
          model: "anthropic.claude-sonnet-4-5-20250929-v1:0",
          usage: { input_tokens: 20, output_tokens: 1 },
        },
      }),
      chunk({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } }),
      chunk({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } }),
      chunk({
        type: "message_stop",
        "amazon-bedrock-invocationMetrics": { inputTokenCount: 20, outputTokenCount: 7 },
      }),
    ];
    const joined = Buffer.concat(frames.map((frame) => Buffer.from(frame)));
    // Deliver in uneven pieces so frame reassembly across chunk boundaries is exercised.
    upstreamResponse = () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new Uint8Array(joined.subarray(0, 7)));
            controller.enqueue(new Uint8Array(joined.subarray(7, 150)));
            controller.enqueue(new Uint8Array(joined.subarray(150)));
            controller.close();
          },
        }),
        { status: 200, headers: { "content-type": "application/vnd.amazon.eventstream" } },
      );
    const response = await messages(
      messagesRequest({ model: "claude-sonnet-4-5", max_tokens: 8, messages: [], stream: true }),
    );
    expect(response.status).toBe(200);
    expect(fetchCalls[0]?.url).toEndWith("/invoke-with-response-stream");
    expect(requestHeaders(fetchCalls[0]!).get("accept")).toBe("application/vnd.amazon.eventstream");
    expect(response.headers.get("content-type")).toBe("text/event-stream; charset=utf-8");
    const text = await response.text();
    const blocks = text.split("\n\n").filter(Boolean);
    expect(blocks).toHaveLength(4);
    expect(blocks[0]).toStartWith("event: message_start\ndata: ");
    const start = JSON.parse(blocks[0]!.split("\ndata: ")[1]!);
    expect(start.message.model).toBe("claude-sonnet-4-5");
    expect(blocks[1]).toBe(
      'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
    );
    expect(blocks[3]).toBe('event: message_stop\ndata: {"type":"message_stop"}');
    const usage = events.find((event) => event.event === "coderouter_model_request_completed");
    expect(usage?.properties).toMatchObject({
      upstream_kind: "bedrock",
      model: "claude-sonnet-4-5",
      input_tokens: 20,
      output_tokens: 7,
      total_tokens: 27,
    });
  });

  test("surfaces stream exceptions as Anthropic error events", async () => {
    const frame = encodeAwsEventStreamMessage(
      { ":message-type": "exception", ":exception-type": "throttlingException" },
      new TextEncoder().encode(JSON.stringify({ message: "Too many requests" })),
    );
    upstreamResponse = () => new Response(new Uint8Array(frame), { status: 200 });
    const response = await messages(
      messagesRequest({ model: "claude-sonnet-4-5", max_tokens: 8, messages: [], stream: true }),
    );
    expect(await response.text()).toBe(
      'event: error\ndata: {"type":"error","error":{"type":"api_error","message":"Too many requests"}}\n\n',
    );
  });

  test("maps Bedrock errors to the Anthropic error shape", async () => {
    upstreamResponse = () =>
      Response.json(
        { message: "Too many tokens per minute" },
        { status: 429, headers: { "x-amzn-errortype": "ThrottlingException", "retry-after": "2" } },
      );
    const response = await messages(messagesRequest());
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("2");
    expect(await response.json()).toEqual({
      type: "error",
      error: { type: "rate_limit_error", message: "Too many tokens per minute" },
    });
  });

  test("rejects models the table does not know", async () => {
    const response = await messages(messagesRequest({ model: "claude-9", max_tokens: 1, messages: [] }));
    expect(response.status).toBe(404);
    expect((await response.json()).error.type).toBe("not_found_error");
    expect(fetchCalls).toHaveLength(0);
  });

  test("honours per-team model overrides and global prefixes", async () => {
    upstream = {
      ...bedrockUpstream,
      config: { region: "eu-west-1", modelIds: { "claude-9": "eu.anthropic.claude-9-v1:0" } },
    };
    upstreamResponse = () => Response.json({ type: "message", usage: {} });
    await messages(messagesRequest({ model: "claude-9", max_tokens: 1, messages: [] }));
    expect(fetchCalls[0]?.url).toBe(
      "https://bedrock-runtime.eu-west-1.amazonaws.com/model/eu.anthropic.claude-9-v1%3A0/invoke",
    );
    await messages(messagesRequest({ model: "global.claude-opus-4-1", max_tokens: 1, messages: [] }));
    expect(fetchCalls[1]?.url).toContain("/model/global.anthropic.claude-opus-4-1-20250805-v1%3A0/invoke");
  });

  test("count_tokens uses the CountTokens API and falls back to an estimate", async () => {
    upstreamResponse = () => Response.json({ inputTokens: 55 });
    const request = () =>
      new Request("https://coderouter.dev/v1/messages/count_tokens", {
        method: "POST",
        headers: { "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: "claude-haiku-4-5", messages: [{ role: "user", content: "hello" }] }),
      });
    const counted = await countTokens(request());
    expect(await counted.json()).toEqual({ input_tokens: 55 });
    expect(fetchCalls[0]?.url).toBe(
      "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-haiku-4-5-20251001-v1%3A0/count-tokens",
    );
    const sent = JSON.parse(await requestBodyText(fetchCalls[0]!));
    const inner = JSON.parse(Buffer.from(sent.input.invokeModel.body, "base64").toString("utf8"));
    expect(inner).toEqual({
      messages: [{ role: "user", content: "hello" }],
      anthropic_version: "bedrock-2023-05-31",
    });

    upstreamResponse = () => Response.json({ message: "no" }, { status: 400 });
    const estimated = await countTokens(request());
    expect(await estimated.json()).toEqual({ input_tokens: Math.ceil(JSON.stringify(inner).length / 4) });
  });

  test("models returns the static catalog in the Anthropic shape", async () => {
    const response = await models(
      new Request("https://coderouter.dev/v1/models", { headers: { "anthropic-version": "2023-06-01" } }),
    );
    const json = await response.json();
    expect(json.has_more).toBe(false);
    expect(json.data.map((model: { id: string }) => model.id)).toContain("claude-sonnet-4-5");
    expect(json.data[0]).toMatchObject({ type: "model" });
    expect(fetchCalls).toHaveLength(0);
  });
});

describe("bedrock helpers", () => {
  test("maps Anthropic ids, dated ids and latest aliases", () => {
    expect(bedrockModelId("claude-opus-4-1")).toBe("anthropic.claude-opus-4-1-20250805-v1:0");
    expect(bedrockModelId("claude-sonnet-4-5-20250929")).toBe("anthropic.claude-sonnet-4-5-20250929-v1:0");
    expect(bedrockModelId("claude-3-5-haiku-latest")).toBe("anthropic.claude-3-5-haiku-20241022-v1:0");
    expect(bedrockModelId("us.anthropic.claude-sonnet-4-20250514-v1:0")).toBe(
      "us.anthropic.claude-sonnet-4-20250514-v1:0",
    );
    expect(bedrockModelId("gpt-5")).toBeNull();
  });

  test("invoke body drops model and stream and pins the version", () => {
    expect(bedrockInvokeBody({ model: "m", stream: true, max_tokens: 1 })).toEqual({
      model: "m",
      stream: true,
      body: { max_tokens: 1, anthropic_version: "bedrock-2023-05-31" },
    });
  });

  test("invoke body drops context_management, which Bedrock rejects as an extra input", () => {
    // Claude Code 2.1.x sends `context_management` under the
    // context-management-2025-06-27 beta; Bedrock's Anthropic Messages API
    // answers 400 "context_management: Extra inputs are not permitted" and
    // every Claude Code turn on a Bedrock team fails. The edit is a
    // client-side optimization, so dropping it keeps the request valid.
    const invoke = bedrockInvokeBody({
      model: "claude-haiku-4-5-20251001",
      stream: true,
      max_tokens: 32000,
      thinking: { type: "enabled", budget_tokens: 31999, display: "omitted" },
      metadata: { user_id: "device" },
      context_management: { edits: [{ type: "clear_thinking_20251015", keep: "all" }] },
      messages: [],
    });
    expect(invoke.body).not.toHaveProperty("context_management");
    expect(invoke.body).toEqual({
      max_tokens: 32000,
      thinking: { type: "enabled", budget_tokens: 31999, display: "omitted" },
      metadata: { user_id: "device" },
      messages: [],
      anthropic_version: "bedrock-2023-05-31",
    });
  });

  test("event-stream decoder parses headers and payload", async () => {
    const frame = encodeAwsEventStreamMessage({ ":event-type": "chunk", ":message-type": "event" }, new Uint8Array([1, 2, 3]));
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(frame);
        controller.close();
      },
    }).pipeThrough(decodeAwsEventStream());
    const reader = stream.getReader();
    const first = await reader.read();
    expect(first.done).toBe(false);
    expect(first.value?.headers).toEqual({ ":event-type": "chunk", ":message-type": "event" });
    expect([...(first.value?.payload ?? [])]).toEqual([1, 2, 3]);
    expect((await reader.read()).done).toBe(true);
  });
});

describe("claude usage parsing", () => {
  test("reads streaming usage from message_start and the last message_delta", () => {
    expect(usageFromText(streamFixture)).toEqual({
      model: "claude-sonnet-4-5-20250929",
      inputTokens: 10,
      cacheReadInputTokens: 100,
      cacheCreationInputTokens: 5,
      outputTokens: 42,
      totalTokens: 157,
    });
  });

  test("reads non-streaming usage", () => {
    const body = JSON.stringify({
      id: "msg",
      model: "claude-haiku-4-5",
      content: [{ type: "text", text: '"usage" is a word' }],
      usage: { input_tokens: 4, output_tokens: 9, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    });
    expect(usageFromText(body)).toEqual({
      model: "claude-haiku-4-5",
      inputTokens: 4,
      cacheReadInputTokens: 0,
      cacheCreationInputTokens: 0,
      outputTokens: 9,
      totalTokens: 13,
    });
  });

  test("returns null without usage", () => {
    expect(usageFromText('{"type":"error"}')).toBeNull();
  });
});

describe("aws sigv4 signer", () => {
  test("matches the AWS SDK signer for a Bedrock invoke", async () => {
    const url = new URL(
      "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-sonnet-4-5-20250929-v1%3A0/invoke",
    );
    const body = new TextEncoder().encode('{"max_tokens":1}');
    const now = new Date("2026-09-02T10:00:00.000Z");
    const credentials = {
      accessKeyId: "AKIAIOSFODNN7EXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      sessionToken: "session-token",
    };
    const ours = signAwsRequest({
      method: "POST",
      url,
      headers: new Headers({ "content-type": "application/json", accept: "application/json" }),
      body,
      service: "bedrock",
      region: "us-east-1",
      credentials,
      now,
    });
    class Sha256 {
      private hash: ReturnType<typeof createHash> | ReturnType<typeof createHmac>;
      constructor(secret?: Uint8Array | string) {
        this.hash = secret === undefined ? createHash("sha256") : createHmac("sha256", secret);
      }
      update(data: Uint8Array | string): void {
        this.hash.update(data);
      }
      async digest(): Promise<Uint8Array> {
        return new Uint8Array(this.hash.digest());
      }
    }
    const reference = new SignatureV4({
      service: "bedrock",
      region: "us-east-1",
      credentials,
      sha256: Sha256 as never,
    });
    const signed = await reference.sign(
      {
        method: "POST",
        protocol: "https:",
        hostname: url.hostname,
        path: url.pathname,
        query: {},
        headers: {
          "content-type": "application/json",
          accept: "application/json",
          host: url.host,
          "x-amz-content-sha256": createHash("sha256").update(body).digest("hex"),
        },
        body,
      },
      { signingDate: now },
    );
    expect(ours.get("authorization")).toBe(signed.headers.authorization);
    expect(ours.get("x-amz-date")).toBe(signed.headers["x-amz-date"]);
  });
});
