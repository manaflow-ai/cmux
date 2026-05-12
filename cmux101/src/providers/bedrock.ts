/**
 * AWS Bedrock provider adapter for cmux101.
 *
 * Supports Anthropic Claude models on Bedrock only. Non-Anthropic models
 * (Llama, Mistral, Titan, etc.) will throw a clear ProviderError.
 *
 * Uses @aws-sdk/client-bedrock-runtime's InvokeModelWithResponseStreamCommand.
 * The stream returns Anthropic Messages API events, so translation is identical
 * to the native Anthropic provider.
 */

import {
  BedrockRuntimeClient,
  InvokeModelWithResponseStreamCommand,
  type BedrockRuntimeClientConfig,
} from "@aws-sdk/client-bedrock-runtime";
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
// Helpers: build Anthropic-on-Bedrock request body
// ---------------------------------------------------------------------------

interface BedrockAnthropicBody {
  anthropic_version: "bedrock-2023-05-31";
  max_tokens: number;
  messages: BedrockMessage[];
  system?: string;
  tools?: BedrockTool[];
  temperature?: number;
  top_p?: number;
  stop_sequences?: string[];
}

interface BedrockMessage {
  role: "user" | "assistant";
  content: BedrockContentBlock[];
}

type BedrockContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: unknown }
  | { type: "tool_result"; tool_use_id: string; is_error?: boolean; content: string | BedrockContentBlock[] }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } | { type: "url"; url: string } }
  | { type: "thinking"; thinking: string; signature?: string };

interface BedrockTool {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
}

function toBedrockMessages(messages: Message[]): BedrockMessage[] {
  const result: BedrockMessage[] = [];
  for (const msg of messages) {
    if (msg.role === "system") continue;
    const role: "user" | "assistant" =
      msg.role === "user" || msg.role === "tool" ? "user" : "assistant";
    const content: BedrockContentBlock[] = msg.content.map((block): BedrockContentBlock => {
      switch (block.type) {
        case "text":
          return { type: "text", text: block.text };
        case "tool_use":
          return { type: "tool_use", id: block.id, name: block.name, input: block.input };
        case "tool_result": {
          if (typeof block.content === "string") {
            return { type: "tool_result", tool_use_id: block.tool_use_id, is_error: block.is_error, content: block.content };
          }
          const innerContent: BedrockContentBlock[] = block.content.map((c) => {
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
          return { type: "tool_result", tool_use_id: block.tool_use_id, is_error: block.is_error, content: innerContent };
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

function toBedrockTools(tools: ToolSchema[]): BedrockTool[] {
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.inputSchema,
  }));
}

function buildRequestBody(request: ProviderRequest): BedrockAnthropicBody {
  const { messages, system, tools, maxTokens = 8192, temperature, topP, stopSequences } = request;
  const body: BedrockAnthropicBody = {
    anthropic_version: "bedrock-2023-05-31",
    max_tokens: maxTokens,
    messages: toBedrockMessages(messages),
  };
  if (system) body.system = system;
  if (tools && tools.length > 0) body.tools = toBedrockTools(tools);
  if (temperature !== undefined) body.temperature = temperature;
  if (topP !== undefined) body.top_p = topP;
  if (stopSequences && stopSequences.length > 0) body.stop_sequences = stopSequences;
  return body;
}

// ---------------------------------------------------------------------------
// Stream event translation (Anthropic Messages API shape)
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

type AnthropicStreamEvent =
  | { type: "message_start"; message: { id: string; usage?: { input_tokens: number; output_tokens: number } } }
  | { type: "content_block_start"; index: number; content_block: { type: "text" } | { type: "tool_use"; id: string; name: string } | { type: "thinking" } }
  | { type: "content_block_delta"; index: number; delta: { type: "text_delta"; text: string } | { type: "thinking_delta"; thinking: string } | { type: "input_json_delta"; partial_json: string } | { type: "signature_delta"; signature: string } }
  | { type: "content_block_stop"; index: number }
  | { type: "message_delta"; delta: { stop_reason?: string }; usage?: { output_tokens: number } }
  | { type: "message_stop" }
  | { type: string; [key: string]: unknown };

async function* translateAnthropicStream(
  chunks: AsyncIterable<{ chunk?: { bytes?: Uint8Array } }>,
): AsyncGenerator<StreamEvent> {
  const decoder = new TextDecoder();

  const toolBlockIds = new Map<number, string>();
  const toolInputAccum = new Map<number, string>();
  const blockIsToolUse = new Map<number, boolean>();

  let finalStopReason: StopReason = "end_turn";
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheReadTokens: number | undefined;
  let cacheCreationTokens: number | undefined;
  let messageStartEmitted = false;

  for await (const event of chunks) {
    if (!event.chunk?.bytes) continue;
    const raw = decoder.decode(event.chunk.bytes);
    let parsed: AnthropicStreamEvent;
    try {
      parsed = JSON.parse(raw) as AnthropicStreamEvent;
    } catch {
      continue;
    }

    switch (parsed.type) {
      case "message_start": {
        const msg = (parsed as { type: "message_start"; message: { id: string; usage?: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number; cache_creation_input_tokens?: number } } }).message;
        if (!messageStartEmitted) {
          yield { kind: "message_start", messageId: msg.id };
          messageStartEmitted = true;
        }
        if (msg.usage) {
          inputTokens = msg.usage.input_tokens;
          outputTokens = msg.usage.output_tokens;
          const u = msg.usage as Record<string, unknown>;
          if (typeof u["cache_read_input_tokens"] === "number") cacheReadTokens = u["cache_read_input_tokens"] as number;
          if (typeof u["cache_creation_input_tokens"] === "number") cacheCreationTokens = u["cache_creation_input_tokens"] as number;
        }
        break;
      }

      case "content_block_start": {
        const blk = (parsed as { type: "content_block_start"; index: number; content_block: { type: string; id?: string; name?: string } });
        const cb = blk.content_block;
        if (cb.type === "tool_use" && cb.id && cb.name) {
          blockIsToolUse.set(blk.index, true);
          toolBlockIds.set(blk.index, cb.id);
          toolInputAccum.set(blk.index, "");
          yield { kind: "tool_call_start", id: cb.id, name: cb.name };
        } else {
          blockIsToolUse.set(blk.index, false);
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
    }
  }
}

function wrapBedrockError(err: unknown): ProviderError {
  if (err instanceof Error) {
    const name = err.name;
    // ThrottlingException = 429-like, InternalServerException / ServiceUnavailableException = 5xx
    const retryable =
      name === "ThrottlingException" ||
      name === "ServiceQuotaExceededException" ||
      name === "InternalServerException" ||
      name === "ServiceUnavailableException" ||
      name === "ModelStreamErrorException";
    const status =
      name === "ThrottlingException" || name === "ServiceQuotaExceededException" ? 429
      : name === "InternalServerException" || name === "ServiceUnavailableException" ? 500
      : undefined;
    return new ProviderError(err.message, "bedrock", status, retryable, err);
  }
  return new ProviderError(String(err), "bedrock", undefined, false, err);
}

// ---------------------------------------------------------------------------
// BedrockProvider
// ---------------------------------------------------------------------------

export class BedrockProvider implements Provider {
  readonly id = "bedrock";
  readonly displayName = "AWS Bedrock";

  constructor(private readonly client: BedrockRuntimeClient) {}

  async listModels(): Promise<ModelInfo[]> {
    return [
      {
        id: "anthropic.claude-opus-4-7-20251005-v1:0",
        displayName: "Claude Opus 4.7 (Bedrock)",
        contextWindow: 1_000_000,
        maxOutput: 32_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "anthropic.claude-sonnet-4-6-20250929-v1:0",
        displayName: "Claude Sonnet 4.6 (Bedrock)",
        contextWindow: 1_000_000,
        maxOutput: 16_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "anthropic.claude-haiku-4-5-20251001-v1:0",
        displayName: "Claude Haiku 4.5 (Bedrock)",
        contextWindow: 200_000,
        maxOutput: 8_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
      {
        id: "anthropic.claude-3-5-sonnet-20241022-v2:0",
        displayName: "Claude 3.5 Sonnet v2 (Bedrock)",
        contextWindow: 200_000,
        maxOutput: 8_192,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
      {
        id: "anthropic.claude-3-5-haiku-20241022-v1:0",
        displayName: "Claude 3.5 Haiku (Bedrock)",
        contextWindow: 200_000,
        maxOutput: 8_192,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
    ];
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const { model, abortSignal } = request;

    if (!model.startsWith("anthropic.")) {
      throw new ProviderError(
        `Bedrock provider only supports Anthropic models (model IDs starting with "anthropic."). Got: "${model}". Non-Anthropic models (Llama, Mistral, Titan, etc.) are not supported.`,
        "bedrock",
        400,
        false,
      );
    }

    const body = buildRequestBody(request);
    const bodyBytes = new TextEncoder().encode(JSON.stringify(body));

    const command = new InvokeModelWithResponseStreamCommand({
      modelId: model,
      contentType: "application/json",
      accept: "application/json",
      body: bodyBytes,
    });

    try {
      const response = await this.client.send(command, {
        abortSignal,
      });

      if (!response.body) {
        throw new ProviderError("Bedrock response has no body stream", "bedrock", 500, false);
      }

      yield* translateAnthropicStream(
        response.body as AsyncIterable<{ chunk?: { bytes?: Uint8Array } }>,
      );
    } catch (err) {
      if (err instanceof ProviderError) throw err;
      const providerErr = wrapBedrockError(err);
      yield { kind: "error", error: providerErr };
    }
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export const BedrockProviderFactory: ProviderFactory = {
  id: "bedrock",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    const hasRegion = !!(env["AWS_REGION"] || env["BEDROCK_REGION"]);
    const hasProfile = !!env["AWS_PROFILE"];
    const hasKey = !!env["AWS_ACCESS_KEY_ID"];

    if (!hasRegion && !hasProfile && !hasKey) return null;

    const region = env["BEDROCK_REGION"] ?? env["AWS_REGION"] ?? "us-east-1";
    const client = new BedrockRuntimeClient({ region });
    return new BedrockProvider(client);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const region = (config["region"] as string | undefined) ?? "us-east-1";
    const clientConfig: Record<string, unknown> = { region };

    if (config["accessKeyId"] && config["secretAccessKey"]) {
      clientConfig["credentials"] = {
        accessKeyId: config["accessKeyId"] as string,
        secretAccessKey: config["secretAccessKey"] as string,
        ...(config["sessionToken"] ? { sessionToken: config["sessionToken"] as string } : {}),
      };
    }

    const client = new BedrockRuntimeClient(clientConfig as BedrockRuntimeClientConfig);
    return new BedrockProvider(client);
  },
};
