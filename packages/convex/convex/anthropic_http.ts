import { httpAction } from "./_generated/server";
import { getWorkerAuth } from "./users/utils/getWorkerAuth";
import { env } from "../_shared/convex-env";
import {
  BEDROCK_BASE_URL,
  toBedrockModelId,
  convertBedrockStreamToSSE,
} from "./bedrock_utils";
import { capturePosthogEvent, drainPosthogEvents } from "../_shared/posthog";

const hardCodedApiKey = "sk_placeholder_cmux_anthropic_api_key";

export const CLOUDFLARE_ANTHROPIC_BASE_URL =
  "https://gateway.ai.cloudflare.com/v1/0c1675e0def6de1ab3a50a4e17dc5656/cmux-ai-proxy/anthropic";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

type RoleCounts = Record<string, number>;
type BlockCounts = Record<string, number>;

type SystemSummary = {
  type: "string" | "array" | "none" | "unknown";
  textChars: number;
  blockCount: number;
  blockTypes: BlockCounts;
};

type MessageSummary = {
  count: number;
  roles: RoleCounts;
  contentBlocks: number;
  textChars: number;
  toolUseCount: number;
  toolResultCount: number;
  blockTypes: BlockCounts;
};

type ToolSummary = {
  count: number;
  namePreview: string[];
};

type AnthropicPayloadSummary = {
  model?: string;
  maxTokens?: number;
  stream?: boolean;
  temperature?: number;
  topP?: number;
  topK?: number;
  system: SystemSummary;
  messages: MessageSummary;
  tools: ToolSummary;
  toolChoiceType?: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function incrementCount(target: Record<string, number>, key: string): void {
  target[key] = (target[key] ?? 0) + 1;
}

function summarizeSystem(value: unknown): SystemSummary {
  const summary: SystemSummary = {
    type: "none",
    textChars: 0,
    blockCount: 0,
    blockTypes: {},
  };

  if (typeof value === "string") {
    summary.type = "string";
    summary.textChars = value.length;
    return summary;
  }

  if (Array.isArray(value)) {
    summary.type = "array";
    summary.blockCount = value.length;
    for (const block of value) {
      if (isRecord(block)) {
        const blockType =
          typeof block.type === "string" ? block.type : "unknown";
        incrementCount(summary.blockTypes, blockType);
        if (blockType === "text" && typeof block.text === "string") {
          summary.textChars += block.text.length;
        }
      } else {
        incrementCount(summary.blockTypes, "unknown");
      }
    }
    return summary;
  }

  if (value === undefined) {
    return summary;
  }

  summary.type = "unknown";
  return summary;
}

function summarizeMessages(value: unknown): MessageSummary {
  const summary: MessageSummary = {
    count: 0,
    roles: {},
    contentBlocks: 0,
    textChars: 0,
    toolUseCount: 0,
    toolResultCount: 0,
    blockTypes: {},
  };

  if (!Array.isArray(value)) {
    return summary;
  }

  summary.count = value.length;
  for (const message of value) {
    if (!isRecord(message)) {
      incrementCount(summary.roles, "unknown");
      continue;
    }

    const role = typeof message.role === "string" ? message.role : "unknown";
    incrementCount(summary.roles, role);

    const content = message.content;
    if (typeof content === "string") {
      summary.contentBlocks += 1;
      summary.textChars += content.length;
      incrementCount(summary.blockTypes, "text");
      continue;
    }

    if (Array.isArray(content)) {
      summary.contentBlocks += content.length;
      for (const block of content) {
        if (!isRecord(block)) {
          incrementCount(summary.blockTypes, "unknown");
          continue;
        }
        const blockType =
          typeof block.type === "string" ? block.type : "unknown";
        incrementCount(summary.blockTypes, blockType);

        if (blockType === "text" && typeof block.text === "string") {
          summary.textChars += block.text.length;
        } else if (blockType === "tool_use") {
          summary.toolUseCount += 1;
        } else if (blockType === "tool_result") {
          summary.toolResultCount += 1;
        }
      }
    }
  }

  return summary;
}

function summarizeTools(value: unknown): ToolSummary {
  if (!Array.isArray(value)) {
    return { count: 0, namePreview: [] };
  }

  const names: string[] = [];
  for (const tool of value) {
    if (isRecord(tool) && typeof tool.name === "string") {
      if (names.length < 3) {
        names.push(tool.name);
      }
    }
  }

  return {
    count: value.length,
    namePreview: names,
  };
}

function summarizeAnthropicPayload(body: unknown): AnthropicPayloadSummary {
  if (!isRecord(body)) {
    return {
      system: summarizeSystem(undefined),
      messages: summarizeMessages(undefined),
      tools: { count: 0, namePreview: [] },
    };
  }

  const summary: AnthropicPayloadSummary = {
    model: typeof body.model === "string" ? body.model : undefined,
    maxTokens: typeof body.max_tokens === "number" ? body.max_tokens : undefined,
    stream: typeof body.stream === "boolean" ? body.stream : undefined,
    temperature:
      typeof body.temperature === "number" ? body.temperature : undefined,
    topP: typeof body.top_p === "number" ? body.top_p : undefined,
    topK: typeof body.top_k === "number" ? body.top_k : undefined,
    system: summarizeSystem(body.system),
    messages: summarizeMessages(body.messages),
    tools: summarizeTools(body.tools),
    toolChoiceType: isRecord(body.tool_choice)
      ? typeof body.tool_choice.type === "string"
        ? body.tool_choice.type
        : "object"
      : typeof body.tool_choice === "string"
        ? body.tool_choice
        : undefined,
  };

  return summary;
}

// Source identifies which product/feature is making the API call
type AnthropicProxySource = "cmux" | "preview-new";

type AnthropicProxyEvent = {
  // Core identifiers
  teamId: string;
  userId: string;
  taskRunId: string;

  // Source/product identifier
  source: AnthropicProxySource;

  // Request metadata
  model: string;
  stream: boolean;
  isOAuthToken: boolean;

  // Response metadata
  responseStatus: number;
  latencyMs: number;

  // Token usage (only available for non-streaming responses)
  inputTokens?: number;
  outputTokens?: number;
  cacheCreationInputTokens?: number;
  cacheReadInputTokens?: number;

  // Error info (if applicable)
  errorType?: string;
};

// Map source to span name for PostHog AI analytics
function getSpanName(source: AnthropicProxySource): string {
  switch (source) {
    case "cmux":
      return "claude-code-cmux";
    case "preview-new":
      return "claude-code-preview-new";
  }
}

/**
 * Track Anthropic proxy request in PostHog.
 * Uses PostHog's $ai_generation event for LLM analytics.
 */
function trackAnthropicProxyRequest(event: AnthropicProxyEvent): void {
  capturePosthogEvent({
    distinctId: event.userId,
    event: "$ai_generation",
    properties: {
      // PostHog AI properties
      $ai_model: event.model,
      $ai_provider: "anthropic",
      $ai_input_tokens: event.inputTokens,
      $ai_output_tokens: event.outputTokens,
      $ai_latency: event.latencyMs / 1000, // PostHog expects seconds
      $ai_http_status: event.responseStatus,
      $ai_is_error: event.responseStatus >= 400,
      $ai_error: event.errorType,
      $ai_stream: event.stream,
      $ai_trace_id: event.taskRunId,
      $ai_span_name: getSpanName(event.source),
      $ai_cache_read_input_tokens: event.cacheReadInputTokens,
      $ai_cache_creation_input_tokens: event.cacheCreationInputTokens,

      // Custom cmux properties
      cmux_source: event.source,
      cmux_team_id: event.teamId,
      cmux_task_run_id: event.taskRunId,
      cmux_is_oauth_token: event.isOAuthToken,

      // Associate user properties with this distinctId
      $set: {
        team_id: event.teamId,
      },
    },
  });
}

function getSource(req: Request): AnthropicProxySource {
  const sourceHeader = req.headers.get("x-cmux-source");
  if (sourceHeader === "preview-new") {
    return "preview-new";
  }
  return "cmux";
}

function getIsOAuthToken(token: string | null): boolean {
  return token !== null && token.includes("sk-ant-oat");
}

/**
 * Check if the key is a valid Anthropic API key format.
 * Anthropic keys start with "sk-ant-" (regular) or "sk-ant-oat" (OAuth).
 */
function isAnthropicApiKey(key: string | null): boolean {
  return key !== null && key.startsWith("sk-ant-");
}

/**
 * Check if user provided their own valid Anthropic API key (not the placeholder).
 */
function hasUserApiKey(key: string | null): boolean {
  return key !== null && key !== hardCodedApiKey && isAnthropicApiKey(key);
}

/**
 * HTTP action to proxy Anthropic API requests.
 * Routes to:
 * 1. Anthropic direct (via Cloudflare) - when user provides their own API key
 * 2. AWS Bedrock (direct) - when using platform credits (placeholder key)
 */
export const anthropicProxy = httpAction(async (_ctx, req) => {
  const startTime = Date.now();
  const source = getSource(req);
  const xApiKey = req.headers.get("x-api-key");
  const isOAuthToken = getIsOAuthToken(xApiKey);

  // Try to extract token payload for tracking
  const workerAuth = await getWorkerAuth(req, {
    loggerPrefix: "[anthropic-proxy]",
  });

  // Helper to track events consistently
  const trackEvent = (
    model: string,
    stream: boolean,
    responseStatus: number,
    options?: {
      inputTokens?: number;
      outputTokens?: number;
      cacheCreationInputTokens?: number;
      cacheReadInputTokens?: number;
      errorType?: string;
    }
  ) => {
    trackAnthropicProxyRequest({
      teamId: workerAuth?.payload.teamId ?? "unknown",
      userId: workerAuth?.payload.userId ?? "unknown",
      taskRunId: workerAuth?.payload.taskRunId ?? "unknown",
      source,
      model,
      stream,
      isOAuthToken,
      responseStatus,
      latencyMs: Date.now() - startTime,
      ...options,
    });
  };

  if (!workerAuth) {
    console.error("[anthropic-proxy] Auth error: Missing or invalid token");
    trackEvent("unknown", false, 401, { errorType: "unauthorized" });
    await drainPosthogEvents();
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const useUserApiKey = hasUserApiKey(xApiKey);
    const body = await req.json();
    const requestedModel = body.model ?? "unknown";
    const isStreaming = body.stream ?? false;
    const payloadSummary = summarizeAnthropicPayload(body);

    if (useUserApiKey) {
      // User provided their own Anthropic API key - proxy directly to Anthropic
      const headers: Record<string, string> = {};
      req.headers.forEach((value, key) => {
        // Skip hop-by-hop headers and internal headers
        if (
          !["host", "x-cmux-token", "content-length"].includes(key.toLowerCase())
        ) {
          headers[key] = value;
        }
      });

      const response = await fetch(
        `${CLOUDFLARE_ANTHROPIC_BASE_URL}/v1/messages`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(body),
        }
      );

      // Track non-streaming responses with token usage
      if (!isStreaming) {
        const responseData = await response.clone().json().catch(() => null);
        trackEvent(requestedModel, false, response.status, {
          inputTokens: responseData?.usage?.input_tokens,
          outputTokens: responseData?.usage?.output_tokens,
          cacheCreationInputTokens: responseData?.usage?.cache_creation_input_tokens,
          cacheReadInputTokens: responseData?.usage?.cache_read_input_tokens,
          errorType: response.ok ? undefined : responseData?.error?.type,
        });
        await drainPosthogEvents();
      } else {
        // For streaming, track without token usage (not available until stream ends)
        trackEvent(requestedModel, true, response.status);
        await drainPosthogEvents();
      }

      // Return response directly to user (including any errors)
      return handleResponse(response, isStreaming);
    }

    // AWS Bedrock path: using platform credits (placeholder key)
    {
      const bedrockToken = env.AWS_BEARER_TOKEN_BEDROCK;
      if (!bedrockToken) {
        console.error(
          "[anthropic-proxy] AWS_BEARER_TOKEN_BEDROCK environment variable is not set"
        );
        trackEvent(requestedModel, isStreaming, 503, { errorType: "bedrock_not_configured" });
        await drainPosthogEvents();
        return jsonResponse(
          { error: "Bedrock proxy not configured" },
          503
        );
      }

      const bedrockModelId = toBedrockModelId(requestedModel);
      const streamSuffix = isStreaming ? "-with-response-stream" : "";
      const bedrockUrl = `${BEDROCK_BASE_URL}/model/${bedrockModelId}/invoke${streamSuffix}`;
      console.log("[anthropic-proxy] Bedrock request summary:", {
        requestedModel,
        bedrockModelId,
        stream: payloadSummary.stream ?? false,
        maxTokens: payloadSummary.maxTokens ?? null,
        messageCount: payloadSummary.messages.count,
        contentBlocks: payloadSummary.messages.contentBlocks,
        textChars: payloadSummary.messages.textChars,
        toolUseCount: payloadSummary.messages.toolUseCount,
        toolResultCount: payloadSummary.messages.toolResultCount,
        toolsCount: payloadSummary.tools.count,
        toolNamesPreview: payloadSummary.tools.namePreview,
        toolChoiceType: payloadSummary.toolChoiceType ?? null,
      });

      // Build the Bedrock request body
      // Bedrock uses the same format as Anthropic API but with anthropic_version
      // Remove model (it's in URL) and stream (determined by endpoint suffix)
      const { model: _model, stream: _stream, ...bodyWithoutModelAndStream } = body;
      const bedrockBody = {
        ...bodyWithoutModelAndStream,
        anthropic_version: "bedrock-2023-05-31",
      };

      const response = await fetch(bedrockUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${bedrockToken}`,
        },
        body: JSON.stringify(bedrockBody),
      });

      // Track non-streaming responses with token usage
      if (!isStreaming) {
        const responseData = await response.clone().json().catch(() => null);
        trackEvent(requestedModel, false, response.status, {
          inputTokens: responseData?.usage?.input_tokens,
          outputTokens: responseData?.usage?.output_tokens,
          cacheCreationInputTokens: responseData?.usage?.cache_creation_input_tokens,
          cacheReadInputTokens: responseData?.usage?.cache_read_input_tokens,
          errorType: response.ok ? undefined : responseData?.error?.type,
        });
        await drainPosthogEvents();
      } else {
        // For streaming, track without token usage (not available until stream ends)
        trackEvent(requestedModel, true, response.status);
        await drainPosthogEvents();
      }

      // Pass isBedrock=true to convert streaming format
      return handleResponse(response, isStreaming, true);
    }
  } catch (error) {
    console.error("[anthropic-proxy] Error:", error);
    trackEvent("unknown", false, 500, { errorType: "internal_error" });
    await drainPosthogEvents();
    return jsonResponse({ error: "Failed to proxy request" }, 500);
  }
});

/**
 * Handle API response for both streaming and non-streaming.
 * For Bedrock streaming, converts AWS event stream format to Anthropic SSE format.
 */
async function handleResponse(
  response: Response,
  isStreaming: boolean,
  isBedrock = false
): Promise<Response> {
  if (isStreaming && response.ok) {
    const stream = response.body;
    if (!stream) {
      return jsonResponse({ error: "No response body" }, 500);
    }

    // Bedrock uses AWS event stream binary format, need to convert to SSE
    if (isBedrock) {
      const transformedStream = convertBedrockStreamToSSE(stream);
      return new Response(transformedStream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }

    // Non-Bedrock (Anthropic direct) - pass through as-is
    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  }

  const data = await response.json();

  if (!response.ok) {
    console.error("[anthropic-proxy] API error:", data);
    return jsonResponse(data, response.status);
  }

  return jsonResponse(data);
}

/**
 * Proxy count_tokens to Anthropic directly.
 * Note: This endpoint requires ANTHROPIC_API_KEY to be configured.
 * Bedrock doesn't have an equivalent count_tokens endpoint.
 */
export const anthropicCountTokens = httpAction(async (_ctx, req) => {
  const anthropicApiKey = env.ANTHROPIC_API_KEY;
  if (!anthropicApiKey) {
    // Bedrock doesn't have count_tokens API - return unavailable
    return jsonResponse(
      {
        error: "Token counting is not available in Bedrock-only mode. Configure ANTHROPIC_API_KEY to enable this feature.",
        type: "service_unavailable",
      },
      503
    );
  }

  try {
    const body = await req.json();
    const response = await fetch(
      `${CLOUDFLARE_ANTHROPIC_BASE_URL}/v1/messages/count_tokens`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": anthropicApiKey,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify(body),
      }
    );
    const data = await response.json();
    return jsonResponse(data, response.status);
  } catch (error) {
    console.error("[anthropic-proxy] count_tokens error:", error);
    return jsonResponse(
      { error: "Failed to count tokens", type: "internal_error" },
      500
    );
  }
});

/**
 * Stub handler for event logging - just accept and ignore.
 */
export const anthropicEventLogging = httpAction(async () => {
  return jsonResponse({ success: true });
});
