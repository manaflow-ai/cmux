/**
 * Anthropic provider adapter for cmux101.
 *
 * Translates cmux101's canonical types ↔ @anthropic-ai/sdk, implements
 * prompt caching for multi-turn sessions, and wraps SDK errors into
 * ProviderError.
 */

import Anthropic from "@anthropic-ai/sdk";
import type {
  ContentBlock,
  ImageBlock,
  Message,
  ModelInfo,
  Provider,
  ProviderFactory,
  ProviderRequest,
  StreamEvent,
  StopReason,
  TextBlock,
  ThinkingBlock,
  ToolResultBlock,
  ToolSchema,
  ToolUseBlock,
} from "../core/types.js";
import { ProviderError } from "../core/types.js";

// ---------------------------------------------------------------------------
// Helpers: cmux101 → Anthropic types
// ---------------------------------------------------------------------------

function toAnthropicImageSource(
  img: ImageBlock,
): Anthropic.Base64ImageSource | Anthropic.URLImageSource {
  if (img.source.kind === "base64") {
    return {
      type: "base64",
      media_type: img.source.mediaType as Anthropic.Base64ImageSource["media_type"],
      data: img.source.data,
    };
  }
  return { type: "url", url: img.source.url };
}

function toAnthropicContentBlock(
  block: ContentBlock,
): Anthropic.ContentBlockParam | null {
  switch (block.type) {
    case "text":
      return { type: "text", text: block.text };

    case "tool_use":
      return {
        type: "tool_use",
        id: block.id,
        name: block.name,
        input: block.input as Record<string, unknown>,
      };

    case "tool_result": {
      const content = block.content;
      if (typeof content === "string") {
        return {
          type: "tool_result",
          tool_use_id: block.tool_use_id,
          is_error: block.is_error ?? false,
          content: content,
        };
      }
      return {
        type: "tool_result",
        tool_use_id: block.tool_use_id,
        is_error: block.is_error ?? false,
        content: content.map((c) => {
          if (c.type === "text") return { type: "text" as const, text: c.text };
          return {
            type: "image" as const,
            source: toAnthropicImageSource(c),
          };
        }),
      };
    }

    case "image":
      return {
        type: "image",
        source: toAnthropicImageSource(block),
      };

    case "thinking":
      // Send thinking blocks back to the model with signature
      return {
        type: "thinking",
        thinking: block.thinking,
        signature: block.signature ?? "",
      } as unknown as Anthropic.ContentBlockParam;
  }
}

function toAnthropicMessages(
  messages: Message[],
  applyCache: boolean,
): Anthropic.MessageParam[] {
  const result: Anthropic.MessageParam[] = [];

  for (const msg of messages) {
    if (msg.role === "system") continue; // stripped separately

    const role: "user" | "assistant" =
      msg.role === "user" || msg.role === "tool" ? "user" : "assistant";

    const content: Anthropic.ContentBlockParam[] = msg.content
      .map(toAnthropicContentBlock)
      .filter((b): b is Anthropic.ContentBlockParam => b !== null);

    result.push({ role, content });
  }

  // Apply cache_control to the last user content block for multi-turn caching
  if (applyCache && result.length > 0) {
    const lastMsg = result[result.length - 1];
    if (lastMsg.role === "user" && Array.isArray(lastMsg.content) && lastMsg.content.length > 0) {
      const lastBlock = lastMsg.content[lastMsg.content.length - 1] as unknown as Record<string, unknown>;
      lastBlock["cache_control"] = { type: "ephemeral" };
    }
  }

  return result;
}

function toAnthropicTools(
  tools: ToolSchema[],
  applyCache: boolean,
): Anthropic.Tool[] {
  return tools.map((t, idx) => {
    const tool: Anthropic.Tool = {
      name: t.name,
      description: t.description,
      input_schema: t.inputSchema as Anthropic.Tool["input_schema"],
    };
    // Cache on the last tool when caching is enabled
    if (applyCache && idx === tools.length - 1) {
      (tool as unknown as Record<string, unknown>)["cache_control"] = { type: "ephemeral" };
    }
    return tool;
  });
}

function toStopReason(
  reason: string | null | undefined,
): StopReason {
  switch (reason) {
    case "end_turn":
      return "end_turn";
    case "tool_use":
      return "tool_use";
    case "max_tokens":
      return "max_tokens";
    case "stop_sequence":
      return "stop_sequence";
    default:
      return "end_turn";
  }
}

function wrapError(err: unknown): ProviderError {
  if (err instanceof Anthropic.APIError) {
    const status = err.status ?? 0;
    const retryable = status === 429 || status === 529;
    return new ProviderError(err.message, "anthropic", status, retryable, err);
  }
  const msg = err instanceof Error ? err.message : String(err);
  return new ProviderError(msg, "anthropic", undefined, false, err);
}

// ---------------------------------------------------------------------------
// AnthropicProvider
// ---------------------------------------------------------------------------

export class AnthropicProvider implements Provider {
  readonly id = "anthropic";
  readonly displayName = "Anthropic";

  constructor(private readonly client: Anthropic) {}

  async listModels(): Promise<ModelInfo[]> {
    return [
      {
        id: "claude-opus-4-7",
        displayName: "Claude Opus 4.7",
        contextWindow: 1_000_000,
        maxOutput: 32_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "claude-sonnet-4-6",
        displayName: "Claude Sonnet 4.6",
        contextWindow: 1_000_000,
        maxOutput: 16_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "claude-haiku-4-5",
        displayName: "Claude Haiku 4.5",
        contextWindow: 200_000,
        maxOutput: 8_000,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
    ];
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const {
      model,
      messages,
      system,
      tools,
      maxTokens = 8192,
      stopSequences,
      abortSignal,
    } = request;

    // Prompt caching: enable when >= 3 messages in history
    const applyCache = messages.length >= 3;

    // Build Anthropic params
    const anthropicMessages = toAnthropicMessages(messages, applyCache);
    const anthropicTools = tools && tools.length > 0
      ? toAnthropicTools(tools, applyCache)
      : undefined;

    // System with optional cache_control
    const systemParam: Anthropic.TextBlockParam[] | undefined = system
      ? [
          {
            type: "text",
            text: system,
            ...(applyCache ? { cache_control: { type: "ephemeral" } } : {}),
          } as Anthropic.TextBlockParam,
        ]
      : undefined;

    const params: Anthropic.MessageStreamParams = {
      model,
      max_tokens: maxTokens,
      messages: anthropicMessages,
      ...(systemParam ? { system: systemParam } : {}),
      ...(anthropicTools ? { tools: anthropicTools } : {}),
      ...(stopSequences && stopSequences.length > 0 ? { stop_sequences: stopSequences } : {}),
    };

    try {
      // Use abort signal: create our own controller that mirrors the user signal
      let sdkStream: ReturnType<typeof this.client.messages.stream>;

      if (abortSignal) {
        const controller = new AbortController();
        // Mirror abort
        if (abortSignal.aborted) {
          controller.abort();
        } else {
          abortSignal.addEventListener("abort", () => controller.abort(), { once: true });
        }
        sdkStream = this.client.messages.stream(params, { signal: controller.signal });
      } else {
        sdkStream = this.client.messages.stream(params);
      }

      // State for tracking tool call blocks
      const toolBlockIndexToId = new Map<number, string>();
      const toolInputAccumulators = new Map<number, string>(); // index -> accumulated json

      // Track which block indices are tool_use blocks
      const blockIsToolUse = new Map<number, boolean>();

      for await (const event of sdkStream) {
        switch (event.type) {
          case "message_start": {
            yield {
              kind: "message_start",
              messageId: event.message.id,
            };
            break;
          }

          case "content_block_start": {
            const blk = event.content_block;
            if (blk.type === "tool_use") {
              blockIsToolUse.set(event.index, true);
              toolBlockIndexToId.set(event.index, blk.id);
              toolInputAccumulators.set(event.index, "");
              yield {
                kind: "tool_call_start",
                id: blk.id,
                name: blk.name,
              };
            } else {
              blockIsToolUse.set(event.index, false);
            }
            break;
          }

          case "content_block_delta": {
            const delta = event.delta;
            if (delta.type === "text_delta") {
              yield { kind: "text_delta", text: delta.text };
            } else if (delta.type === "thinking_delta") {
              yield { kind: "thinking_delta", text: delta.thinking };
            } else if (delta.type === "input_json_delta") {
              const toolId = toolBlockIndexToId.get(event.index);
              if (toolId !== undefined) {
                const current = toolInputAccumulators.get(event.index) ?? "";
                toolInputAccumulators.set(event.index, current + delta.partial_json);
                yield {
                  kind: "tool_call_input_delta",
                  id: toolId,
                  jsonDelta: delta.partial_json,
                };
              }
            } else if ((delta as { type: string }).type === "signature_delta") {
              // thinking block finalization with signature — forward as thinking_delta with signature
              const sig = (delta as unknown as { signature: string }).signature;
              yield { kind: "thinking_delta", text: "", signature: sig };
            }
            break;
          }

          case "content_block_stop": {
            if (blockIsToolUse.get(event.index)) {
              const toolId = toolBlockIndexToId.get(event.index);
              if (toolId !== undefined) {
                const accumulated = toolInputAccumulators.get(event.index) ?? "";
                let parsedInput: unknown = {};
                if (accumulated.trim()) {
                  try {
                    parsedInput = JSON.parse(accumulated);
                  } catch {
                    parsedInput = {};
                  }
                }
                yield {
                  kind: "tool_call_end",
                  id: toolId,
                  input: parsedInput,
                };
              }
            }
            break;
          }

          case "message_delta": {
            // Usage may come here
            if (event.usage) {
              yield {
                kind: "usage",
                inputTokens: 0, // will get final usage in message_stop/finalMessage
                outputTokens: event.usage.output_tokens,
              };
            }
            break;
          }

          case "message_stop": {
            // Get the final message for complete usage info
            try {
              const finalMsg = await sdkStream.finalMessage();
              yield {
                kind: "usage",
                inputTokens: finalMsg.usage.input_tokens,
                outputTokens: finalMsg.usage.output_tokens,
                cacheReadTokens: (finalMsg.usage as unknown as Record<string, unknown>)["cache_read_input_tokens"] as number | undefined,
                cacheCreationTokens: (finalMsg.usage as unknown as Record<string, unknown>)["cache_creation_input_tokens"] as number | undefined,
              };
              yield {
                kind: "message_stop",
                reason: toStopReason(finalMsg.stop_reason),
              };
            } catch {
              yield {
                kind: "message_stop",
                reason: "end_turn",
              };
            }
            return;
          }
        }
      }
    } catch (err) {
      const providerErr = wrapError(err);
      yield { kind: "error", error: providerErr };
    }
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export const AnthropicProviderFactory: ProviderFactory = {
  id: "anthropic",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    const apiKey = env["ANTHROPIC_API_KEY"];
    if (!apiKey) return null;
    const baseURL = env["ANTHROPIC_BASE_URL"];
    const client = new Anthropic({ apiKey, ...(baseURL ? { baseURL } : {}) });
    return new AnthropicProvider(client);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const apiKey = config["apiKey"] as string | undefined;
    const baseURL = config["baseURL"] as string | undefined;
    const client = new Anthropic({
      ...(apiKey ? { apiKey } : {}),
      ...(baseURL ? { baseURL } : {}),
    });
    return new AnthropicProvider(client);
  },
};
