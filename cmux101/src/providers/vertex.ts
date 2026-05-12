/**
 * Google Vertex AI provider adapter for cmux101.
 *
 * Supports Anthropic Claude models on Vertex AI via REST/SSE.
 * Uses google-auth-library to mint GCP access tokens.
 *
 * Endpoint:
 *   POST https://<region>-aiplatform.googleapis.com/v1/projects/<project>/locations/<region>/publishers/anthropic/models/<model>:streamRawPredict
 *
 * Request body uses Anthropic Messages API format with anthropic_version "vertex-2023-10-16".
 * Response is SSE — each event has the same shape as Anthropic native.
 */

import { GoogleAuth } from "google-auth-library";
import type {
  Message,
  ModelInfo,
  Provider,
  ProviderFactory,
  ProviderRequest,
  StreamEvent,
  StopReason,
  ToolSchema,
} from "../core/types.js";
import { ProviderError } from "../core/types.js";

// ---------------------------------------------------------------------------
// Helpers: build Vertex/Anthropic request body
// ---------------------------------------------------------------------------

interface VertexAnthropicBody {
  anthropic_version: "vertex-2023-10-16";
  max_tokens: number;
  messages: VertexMessage[];
  stream: true;
  system?: string;
  tools?: VertexTool[];
  temperature?: number;
  top_p?: number;
  stop_sequences?: string[];
}

interface VertexMessage {
  role: "user" | "assistant";
  content: VertexContentBlock[];
}

type VertexContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: unknown }
  | { type: "tool_result"; tool_use_id: string; is_error?: boolean; content: string | VertexContentBlock[] }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } | { type: "url"; url: string } }
  | { type: "thinking"; thinking: string; signature?: string };

interface VertexTool {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
}

function toVertexMessages(messages: Message[]): VertexMessage[] {
  const result: VertexMessage[] = [];
  for (const msg of messages) {
    if (msg.role === "system") continue;
    const role: "user" | "assistant" =
      msg.role === "user" || msg.role === "tool" ? "user" : "assistant";
    const content: VertexContentBlock[] = msg.content.map((block): VertexContentBlock => {
      switch (block.type) {
        case "text":
          return { type: "text", text: block.text };
        case "tool_use":
          return { type: "tool_use", id: block.id, name: block.name, input: block.input };
        case "tool_result": {
          if (typeof block.content === "string") {
            return { type: "tool_result", tool_use_id: block.tool_use_id, is_error: block.is_error, content: block.content };
          }
          const inner: VertexContentBlock[] = block.content.map((c) => {
            if (c.type === "text") return { type: "text" as const, text: c.text };
            if (c.source.kind === "base64") {
              return {
                type: "image" as const,
                source: { type: "base64" as const, media_type: c.source.mediaType, data: c.source.data },
              };
            }
            return {
              type: "image" as const,
              source: { type: "url" as const, url: (c.source as { url: string }).url },
            };
          });
          return { type: "tool_result", tool_use_id: block.tool_use_id, is_error: block.is_error, content: inner };
        }
        case "image":
          if (block.source.kind === "base64") {
            return {
              type: "image",
              source: { type: "base64", media_type: block.source.mediaType, data: block.source.data },
            };
          }
          return {
            type: "image",
            source: { type: "url", url: (block.source as { url: string }).url },
          };
        case "thinking":
          return { type: "thinking", thinking: block.thinking, signature: block.signature };
      }
    });
    result.push({ role, content });
  }
  return result;
}

function toVertexTools(tools: ToolSchema[]): VertexTool[] {
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.inputSchema,
  }));
}

function buildRequestBody(request: ProviderRequest): VertexAnthropicBody {
  const { messages, system, tools, maxTokens = 8192, temperature, topP, stopSequences } = request;
  const body: VertexAnthropicBody = {
    anthropic_version: "vertex-2023-10-16",
    max_tokens: maxTokens,
    messages: toVertexMessages(messages),
    stream: true,
  };
  if (system) body.system = system;
  if (tools && tools.length > 0) body.tools = toVertexTools(tools);
  if (temperature !== undefined) body.temperature = temperature;
  if (topP !== undefined) body.top_p = topP;
  if (stopSequences && stopSequences.length > 0) body.stop_sequences = stopSequences;
  return body;
}

// ---------------------------------------------------------------------------
// SSE parser + stream event translation
// ---------------------------------------------------------------------------

function toStopReason(reason: string | null | undefined): StopReason {
  switch (reason) {
    case "end_turn": return "end_turn";
    case "tool_use": return "tool_use";
    case "max_tokens": return "max_tokens";
    case "stop_sequence": return "stop_sequence";
    default: return "end_turn";
  }
}

type AnthropicSSEEvent =
  | { type: "message_start"; message: { id: string; usage?: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number } } }
  | { type: "content_block_start"; index: number; content_block: { type: string; id?: string; name?: string } }
  | { type: "content_block_delta"; index: number; delta: { type: string; text?: string; thinking?: string; partial_json?: string; signature?: string } }
  | { type: "content_block_stop"; index: number }
  | { type: "message_delta"; delta: { stop_reason?: string }; usage?: { output_tokens: number } }
  | { type: "message_stop" }
  | { type: "error"; error?: { message?: string } }
  | { type: string; [key: string]: unknown };

/**
 * Parse a raw SSE line buffer into (event, data) pairs.
 * SSE format: "data: {...}" lines. We only care about "data:" lines.
 */
function parseSseLine(line: string): string | null {
  if (line.startsWith("data: ")) {
    return line.slice(6).trim();
  }
  return null;
}

async function* translateVertexSSE(
  responseBody: ReadableStream<Uint8Array>,
  abortSignal?: AbortSignal,
): AsyncGenerator<StreamEvent> {
  const decoder = new TextDecoder();
  const reader = responseBody.getReader();

  const toolBlockIds = new Map<number, string>();
  const toolInputAccum = new Map<number, string>();
  const blockIsToolUse = new Map<number, boolean>();

  let finalStopReason: StopReason = "end_turn";
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheReadTokens: number | undefined;
  let cacheCreationTokens: number | undefined;

  let buffer = "";

  try {
    while (true) {
      if (abortSignal?.aborted) {
        reader.cancel();
        return;
      }

      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // Process complete lines
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const data = parseSseLine(line);
        if (!data || data === "[DONE]") continue;

        let parsed: AnthropicSSEEvent;
        try {
          parsed = JSON.parse(data) as AnthropicSSEEvent;
        } catch {
          continue;
        }

        switch (parsed.type) {
          case "message_start": {
            const msg = (parsed as { type: "message_start"; message: { id: string; usage?: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number } } }).message;
            yield { kind: "message_start", messageId: msg.id };
            if (msg.usage) {
              inputTokens = msg.usage.input_tokens;
              outputTokens = msg.usage.output_tokens;
              if (typeof msg.usage.cache_read_input_tokens === "number") cacheReadTokens = msg.usage.cache_read_input_tokens;
              if (typeof msg.usage.cache_creation_input_tokens === "number") cacheCreationTokens = msg.usage.cache_creation_input_tokens;
            }
            break;
          }

          case "content_block_start": {
            const ev = parsed as { type: "content_block_start"; index: number; content_block: { type: string; id?: string; name?: string } };
            const cb = ev.content_block;
            if (cb.type === "tool_use" && cb.id && cb.name) {
              blockIsToolUse.set(ev.index, true);
              toolBlockIds.set(ev.index, cb.id);
              toolInputAccum.set(ev.index, "");
              yield { kind: "tool_call_start", id: cb.id, name: cb.name };
            } else {
              blockIsToolUse.set(ev.index, false);
            }
            break;
          }

          case "content_block_delta": {
            const ev = parsed as { type: "content_block_delta"; index: number; delta: { type: string; text?: string; thinking?: string; partial_json?: string; signature?: string } };
            const { index, delta } = ev;
            if (delta.type === "text_delta" && delta.text !== undefined) {
              yield { kind: "text_delta", text: delta.text };
            } else if (delta.type === "thinking_delta" && delta.thinking !== undefined) {
              yield { kind: "thinking_delta", text: delta.thinking };
            } else if (delta.type === "input_json_delta" && delta.partial_json !== undefined) {
              const toolId = toolBlockIds.get(index);
              if (toolId !== undefined) {
                const current = toolInputAccum.get(index) ?? "";
                toolInputAccum.set(index, current + delta.partial_json);
                yield { kind: "tool_call_input_delta", id: toolId, jsonDelta: delta.partial_json };
              }
            } else if (delta.type === "signature_delta" && delta.signature !== undefined) {
              yield { kind: "thinking_delta", text: "", signature: delta.signature };
            }
            break;
          }

          case "content_block_stop": {
            const ev = parsed as { type: "content_block_stop"; index: number };
            if (blockIsToolUse.get(ev.index)) {
              const toolId = toolBlockIds.get(ev.index);
              if (toolId !== undefined) {
                const accumulated = toolInputAccum.get(ev.index) ?? "";
                let parsedInput: unknown = {};
                if (accumulated.trim()) {
                  try { parsedInput = JSON.parse(accumulated); } catch { parsedInput = {}; }
                }
                yield { kind: "tool_call_end", id: toolId, input: parsedInput };
              }
            }
            break;
          }

          case "message_delta": {
            const ev = parsed as { type: "message_delta"; delta: { stop_reason?: string }; usage?: { output_tokens: number } };
            if (ev.delta.stop_reason) finalStopReason = toStopReason(ev.delta.stop_reason);
            if (ev.usage) outputTokens = ev.usage.output_tokens;
            break;
          }

          case "message_stop": {
            yield {
              kind: "usage",
              inputTokens,
              outputTokens,
              ...(cacheReadTokens !== undefined ? { cacheReadTokens } : {}),
              ...(cacheCreationTokens !== undefined ? { cacheCreationTokens } : {}),
            };
            yield { kind: "message_stop", reason: finalStopReason };
            return;
          }

          case "error": {
            const ev = parsed as { type: "error"; error?: { message?: string } };
            throw new ProviderError(
              ev.error?.message ?? "Vertex AI stream error",
              "vertex",
              undefined,
              false,
            );
          }
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function wrapVertexError(err: unknown): ProviderError {
  if (err instanceof ProviderError) return err;
  if (err instanceof Error) {
    return new ProviderError(err.message, "vertex", undefined, false, err);
  }
  return new ProviderError(String(err), "vertex", undefined, false, err);
}

// ---------------------------------------------------------------------------
// VertexProvider
// ---------------------------------------------------------------------------

export class VertexProvider implements Provider {
  readonly id = "vertex";
  readonly displayName = "Google Vertex AI";

  private readonly auth: GoogleAuth;

  constructor(
    private readonly project: string,
    private readonly region: string,
  ) {
    this.auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    });
  }

  async listModels(): Promise<ModelInfo[]> {
    return [
      {
        id: "claude-opus-4-7@20251005",
        displayName: "Claude Opus 4.7 (Vertex)",
        contextWindow: 1_000_000,
        maxOutput: 32_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "claude-sonnet-4-6@20250929",
        displayName: "Claude Sonnet 4.6 (Vertex)",
        contextWindow: 1_000_000,
        maxOutput: 16_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "claude-haiku-4-5@20251001",
        displayName: "Claude Haiku 4.5 (Vertex)",
        contextWindow: 200_000,
        maxOutput: 8_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
    ];
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const { model, abortSignal } = request;

    let accessToken: string | null | undefined;
    try {
      accessToken = await this.auth.getAccessToken();
    } catch (err) {
      throw new ProviderError(
        `Vertex AI: failed to obtain access token: ${err instanceof Error ? err.message : String(err)}`,
        "vertex",
        401,
        false,
        err,
      );
    }

    if (!accessToken) {
      throw new ProviderError(
        "Vertex AI: could not obtain access token (no credentials found)",
        "vertex",
        401,
        false,
      );
    }

    const endpoint = `https://${this.region}-aiplatform.googleapis.com/v1/projects/${this.project}/locations/${this.region}/publishers/anthropic/models/${model}:streamRawPredict`;

    const body = buildRequestBody(request);

    let response: Response;
    try {
      response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: abortSignal,
      });
    } catch (err) {
      if (err instanceof ProviderError) throw err;
      throw new ProviderError(
        `Vertex AI: network error: ${err instanceof Error ? err.message : String(err)}`,
        "vertex",
        undefined,
        true,
        err,
      );
    }

    if (!response.ok) {
      const status = response.status;
      const retryable = status === 429 || status >= 500;
      let message = `Vertex AI: HTTP ${status}`;
      try {
        const text = await response.text();
        if (text) message = `Vertex AI: HTTP ${status}: ${text.slice(0, 300)}`;
      } catch {
        // ignore body read error
      }
      throw new ProviderError(message, "vertex", status, retryable);
    }

    if (!response.body) {
      throw new ProviderError("Vertex AI response has no body", "vertex", 500, false);
    }

    try {
      yield* translateVertexSSE(response.body, abortSignal);
    } catch (err) {
      const providerErr = wrapVertexError(err);
      yield { kind: "error", error: providerErr };
    }
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export const VertexProviderFactory: ProviderFactory = {
  id: "vertex",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    const project = env["GOOGLE_CLOUD_PROJECT"];
    if (!project) return null;

    // Require either GOOGLE_APPLICATION_CREDENTIALS (SA key file) or assume GCP metadata server
    const hasCreds = !!(env["GOOGLE_APPLICATION_CREDENTIALS"]);
    // Also accept GCP-ambient auth (no explicit check needed; google-auth-library handles it)
    // We require the project at minimum so we can build the endpoint URL.
    // If hasCreds is false, we still allow it — google-auth-library will try ADC.

    const region = env["VERTEX_REGION"] ?? "us-east5";
    return new VertexProvider(project, region);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const project = config["project"] as string | undefined;
    if (!project) {
      throw new ProviderError(
        "Vertex AI: 'project' (GOOGLE_CLOUD_PROJECT) is required",
        "vertex",
        undefined,
        false,
      );
    }
    const region = (config["region"] as string | undefined) ?? "us-east5";
    return new VertexProvider(project, region);
  },
};
