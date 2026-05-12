/**
 * OpenAI provider adapter for cmux101.
 * Translates cmux101 canonical types <-> OpenAI Chat Completions API.
 */

import OpenAI from "openai";
import type {
  ChatCompletionMessageParam,
  ChatCompletionUserMessageParam,
  ChatCompletionContentPart,
} from "openai/resources/chat/completions";
import type {
  Provider,
  ProviderFactory,
  ProviderRequest,
  ModelInfo,
  StreamEvent,
  StopReason,
  Message,
  ContentBlock,
} from "../core/types.js";
import { ProviderError } from "../core/types.js";

// ---------------------------------------------------------------------------
// Model catalogue
// ---------------------------------------------------------------------------

const MODELS: ModelInfo[] = [
  {
    id: "gpt-4o",
    displayName: "GPT-4o",
    contextWindow: 128_000,
    maxOutput: 16_384,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "gpt-4o-mini",
    displayName: "GPT-4o mini",
    contextWindow: 128_000,
    maxOutput: 16_384,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "gpt-4.1",
    displayName: "GPT-4.1",
    contextWindow: 1_047_576,
    maxOutput: 32_768,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "gpt-4.1-mini",
    displayName: "GPT-4.1 mini",
    contextWindow: 1_047_576,
    maxOutput: 32_768,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "gpt-4.1-nano",
    displayName: "GPT-4.1 nano",
    contextWindow: 1_047_576,
    maxOutput: 32_768,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "o1",
    displayName: "o1",
    contextWindow: 200_000,
    maxOutput: 100_000,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: true,
  },
  {
    id: "o1-mini",
    displayName: "o1 mini",
    contextWindow: 128_000,
    maxOutput: 65_536,
    supportsTools: false,
    supportsVision: false,
    supportsThinking: true,
  },
  {
    id: "o3",
    displayName: "o3",
    contextWindow: 200_000,
    maxOutput: 100_000,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: true,
  },
  {
    id: "o3-mini",
    displayName: "o3 mini",
    contextWindow: 200_000,
    maxOutput: 100_000,
    supportsTools: true,
    supportsVision: false,
    supportsThinking: true,
  },
  {
    id: "o4-mini",
    displayName: "o4 mini",
    contextWindow: 200_000,
    maxOutput: 100_000,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: true,
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Returns true for o-series models which need special parameter handling. */
function isOSeries(model: string): boolean {
  return /^o[134]/.test(model);
}

function isRetryable(status: number | undefined): boolean {
  return status !== undefined && [429, 500, 502, 503, 504].includes(status);
}

/**
 * Convert a cmux101 Message array into OpenAI ChatCompletionMessageParam[].
 * Thinking blocks are silently dropped (OpenAI doesn't accept them as input).
 */
export function translateMessages(messages: Message[]): ChatCompletionMessageParam[] {
  const result: ChatCompletionMessageParam[] = [];

  for (const msg of messages) {
    const { role, content } = msg;

    if (role === "system") {
      // Collect all text blocks
      const text = content
        .filter((b): b is Extract<ContentBlock, { type: "text" }> => b.type === "text")
        .map((b) => b.text)
        .join("\n");
      result.push({ role: "system", content: text });
      continue;
    }

    if (role === "user") {
      // Check for image blocks
      const hasImages = content.some((b) => b.type === "image");
      if (hasImages) {
        const parts: ChatCompletionContentPart[] = [];
        for (const block of content) {
          if (block.type === "text") {
            parts.push({ type: "text", text: block.text });
          } else if (block.type === "image") {
            const src = block.source;
            const url =
              src.kind === "base64"
                ? `data:${src.mediaType};base64,${src.data}`
                : src.url;
            parts.push({
              type: "image_url",
              image_url: { url },
            });
          }
          // thinking blocks silently dropped
        }
        const userMsg: ChatCompletionUserMessageParam = { role: "user", content: parts };
        result.push(userMsg);
      } else {
        // Text-only user message
        const text = content
          .filter((b): b is Extract<ContentBlock, { type: "text" }> => b.type === "text")
          .map((b) => b.text)
          .join("\n");
        result.push({ role: "user", content: text });
      }
      continue;
    }

    if (role === "assistant") {
      // Check for tool_use blocks
      const toolUseBlocks = content.filter(
        (b): b is Extract<ContentBlock, { type: "tool_use" }> => b.type === "tool_use"
      );
      if (toolUseBlocks.length > 0) {
        result.push({
          role: "assistant",
          content: null,
          tool_calls: toolUseBlocks.map((b) => ({
            id: b.id,
            type: "function" as const,
            function: {
              name: b.name,
              arguments: JSON.stringify(b.input),
            },
          })),
        });
      } else {
        // Text-only assistant message (thinking blocks dropped)
        const text = content
          .filter((b): b is Extract<ContentBlock, { type: "text" }> => b.type === "text")
          .map((b) => b.text)
          .join("\n");
        result.push({ role: "assistant", content: text });
      }
      continue;
    }

    if (role === "tool") {
      for (const block of content) {
        if (block.type === "tool_result") {
          const contentStr =
            typeof block.content === "string"
              ? block.content
              : JSON.stringify(block.content);
          result.push({
            role: "tool",
            tool_call_id: block.tool_use_id,
            content: contentStr,
          });
        }
      }
      continue;
    }
  }

  return result;
}

/**
 * Map OpenAI finish_reason to cmux101 StopReason.
 */
export function mapFinishReason(
  finishReason: string | null | undefined
): StopReason {
  switch (finishReason) {
    case "stop":
      return "end_turn";
    case "tool_calls":
      return "tool_use";
    case "length":
      return "max_tokens";
    case "content_filter":
      return "refusal";
    default:
      return "end_turn";
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export class OpenAIProvider implements Provider {
  readonly id = "openai";
  readonly displayName = "OpenAI";

  private client: OpenAI;

  constructor(client: OpenAI) {
    this.client = client;
  }

  async listModels(): Promise<ModelInfo[]> {
    return MODELS;
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const {
      model,
      messages,
      system,
      tools,
      maxTokens,
      temperature,
      topP,
      stopSequences,
      abortSignal,
    } = request;

    // Build message list (prepend system if provided)
    const allMessages: Message[] = system
      ? [{ role: "system", content: [{ type: "text", text: system }] }, ...messages]
      : messages;

    const openaiMessages = translateMessages(allMessages);

    const oSeries = isOSeries(model);

    // Build request params
    const params: Record<string, unknown> = {
      model,
      messages: openaiMessages,
      stream: true,
      stream_options: { include_usage: true },
    };

    if (maxTokens !== undefined) {
      if (oSeries) {
        params.max_completion_tokens = maxTokens;
      } else {
        params.max_tokens = maxTokens;
      }
    }

    if (!oSeries) {
      if (temperature !== undefined) params.temperature = temperature;
      if (topP !== undefined) params.top_p = topP;
    }

    if (stopSequences && stopSequences.length > 0) {
      params.stop = stopSequences;
    }

    if (tools && tools.length > 0) {
      params.tools = tools.map((t) => ({
        type: "function" as const,
        function: {
          name: t.name,
          description: t.description,
          parameters: t.inputSchema,
        },
      }));
    }

    let streamInstance: Awaited<ReturnType<typeof this.client.chat.completions.create>>;
    try {
      streamInstance = await this.client.chat.completions.create(
        params as unknown as Parameters<typeof this.client.chat.completions.create>[0],
        { signal: abortSignal }
      );
    } catch (err) {
      throw this.wrapError(err);
    }

    // Per-tool-call accumulator: index -> { id, name, args }
    const toolCallAccumulator: Map<
      number,
      { id: string; name: string; args: string }
    > = new Map();

    let messageStartEmitted = false;
    let finishReason: string | null | undefined = null;

    try {
      for await (const chunk of streamInstance as AsyncIterable<OpenAI.Chat.Completions.ChatCompletionChunk>) {
        if (!messageStartEmitted) {
          yield { kind: "message_start", messageId: chunk.id };
          messageStartEmitted = true;
        }

        const choice = chunk.choices?.[0];

        if (choice) {
          const delta = choice.delta;
          if (delta) {
            // Text delta
            if (delta.content) {
              yield { kind: "text_delta", text: delta.content };
            }

            // Tool call deltas
            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index;
                if (!toolCallAccumulator.has(idx)) {
                  // New tool call
                  const id = tc.id ?? "";
                  const name = tc.function?.name ?? "";
                  toolCallAccumulator.set(idx, { id, name, args: "" });
                  yield { kind: "tool_call_start", id, name };
                }

                const entry = toolCallAccumulator.get(idx)!;

                // Update id/name if they arrive later
                if (tc.id && !entry.id) entry.id = tc.id;
                if (tc.function?.name && !entry.name) entry.name = tc.function.name;

                // Accumulate arguments
                if (tc.function?.arguments) {
                  entry.args += tc.function.arguments;
                  yield {
                    kind: "tool_call_input_delta",
                    id: entry.id,
                    jsonDelta: tc.function.arguments,
                  };
                }
              }
            }
          }

          if (choice.finish_reason) {
            finishReason = choice.finish_reason;
          }
        }

        // Usage from final chunk
        if (chunk.usage) {
          yield {
            kind: "usage",
            inputTokens: chunk.usage.prompt_tokens ?? 0,
            outputTokens: chunk.usage.completion_tokens ?? 0,
          };
        }
      }
    } catch (err) {
      throw this.wrapError(err);
    }

    // Emit tool_call_end for all accumulated tool calls
    for (const [, entry] of toolCallAccumulator) {
      let input: unknown;
      try {
        input = JSON.parse(entry.args);
      } catch {
        input = {};
      }
      yield { kind: "tool_call_end", id: entry.id, input };
    }

    // Emit message_stop
    yield { kind: "message_stop", reason: mapFinishReason(finishReason) };
  }

  private wrapError(err: unknown): ProviderError {
    if (err instanceof OpenAI.APIError) {
      return new ProviderError(
        err.message,
        "openai",
        err.status,
        isRetryable(err.status),
        err
      );
    }
    if (err instanceof ProviderError) return err;
    const msg = err instanceof Error ? err.message : String(err);
    return new ProviderError(msg, "openai", undefined, false, err);
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export class OpenAIProviderFactory implements ProviderFactory {
  readonly id = "openai";

  fromEnv(env: NodeJS.ProcessEnv): OpenAIProvider | null {
    const apiKey = env.OPENAI_API_KEY;
    if (!apiKey) return null;
    const client = new OpenAI({
      apiKey,
      baseURL: env.OPENAI_BASE_URL,
      organization: env.OPENAI_ORGANIZATION,
    });
    return new OpenAIProvider(client);
  }

  fromConfig(config: Record<string, unknown>): OpenAIProvider {
    const apiKey = config.apiKey as string | undefined;
    if (!apiKey) {
      throw new ProviderError("Missing apiKey in config", "openai");
    }
    const client = new OpenAI({
      apiKey,
      baseURL: config.baseURL as string | undefined,
      organization: config.organization as string | undefined,
    });
    return new OpenAIProvider(client);
  }
}
