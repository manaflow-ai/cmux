/**
 * Alibaba DashScope (Qwen) provider adapter for cmux101.
 *
 * DashScope exposes an OpenAI-compatible chat completions API.
 * Stream translation follows openai.ts with one addition: reasoning variants
 * (qwen-qwq-*, qwq-*, or models containing -thinking) reject temperature and
 * top_p, so those params are stripped before sending.
 */

import OpenAI from "openai";
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
import type {
  ChatCompletionMessageParam,
  ChatCompletionContentPart,
} from "openai/resources/chat/completions";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1";

// ---------------------------------------------------------------------------
// Model catalogue
// ---------------------------------------------------------------------------

const MODELS: ModelInfo[] = [
  {
    id: "qwen-max",
    displayName: "Qwen Max",
    contextWindow: 32_768,
    maxOutput: 8_192,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "qwen-plus",
    displayName: "Qwen Plus",
    contextWindow: 131_072,
    maxOutput: 8_192,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "qwen-turbo",
    displayName: "Qwen Turbo",
    contextWindow: 131_072,
    maxOutput: 8_192,
    supportsTools: true,
    supportsVision: false,
    supportsThinking: false,
  },
  {
    id: "qwen-coder-plus",
    displayName: "Qwen Coder Plus",
    contextWindow: 131_072,
    maxOutput: 8_192,
    supportsTools: true,
    supportsVision: false,
    supportsThinking: false,
  },
  {
    id: "qwen3-coder",
    displayName: "Qwen3 Coder",
    contextWindow: 262_144,
    maxOutput: 16_384,
    supportsTools: true,
    supportsVision: false,
    supportsThinking: false,
  },
  {
    id: "qwq-32b-preview",
    displayName: "QwQ 32B Preview",
    contextWindow: 32_768,
    maxOutput: 32_768,
    supportsTools: false,
    supportsVision: false,
    supportsThinking: true,
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Returns true for reasoning variants that reject temperature/top_p.
 */
export function isReasoningModel(model: string): boolean {
  return (
    model.startsWith("qwen-qwq-") ||
    model.startsWith("qwq-") ||
    model.includes("-thinking")
  );
}

function mapFinishReason(finishReason: string | null | undefined): StopReason {
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

function isRetryable(status: number | undefined): boolean {
  return status !== undefined && [429, 500, 502, 503, 504].includes(status);
}

// ---------------------------------------------------------------------------
// Message translation helper (identical logic to openai.ts)
// ---------------------------------------------------------------------------

export function translateMessages(messages: Message[]): ChatCompletionMessageParam[] {
  const result: ChatCompletionMessageParam[] = [];

  for (const msg of messages) {
    const { role, content } = msg;

    if (role === "system") {
      const text = content
        .filter((b): b is Extract<ContentBlock, { type: "text" }> => b.type === "text")
        .map((b) => b.text)
        .join("\n");
      result.push({ role: "system", content: text });
      continue;
    }

    if (role === "user") {
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
            parts.push({ type: "image_url", image_url: { url } });
          }
        }
        result.push({ role: "user", content: parts });
      } else {
        const text = content
          .filter((b): b is Extract<ContentBlock, { type: "text" }> => b.type === "text")
          .map((b) => b.text)
          .join("\n");
        result.push({ role: "user", content: text });
      }
      continue;
    }

    if (role === "assistant") {
      const toolUseBlocks = content.filter(
        (b): b is Extract<ContentBlock, { type: "tool_use" }> => b.type === "tool_use",
      );
      if (toolUseBlocks.length > 0) {
        result.push({
          role: "assistant",
          content: null,
          tool_calls: toolUseBlocks.map((b) => ({
            id: b.id,
            type: "function" as const,
            function: { name: b.name, arguments: JSON.stringify(b.input) },
          })),
        });
      } else {
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
          result.push({ role: "tool", tool_call_id: block.tool_use_id, content: contentStr });
        }
      }
      continue;
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// DashScopeProvider
// ---------------------------------------------------------------------------

export class DashScopeProvider implements Provider {
  readonly id = "dashscope";
  readonly displayName = "Alibaba DashScope (Qwen)";

  private client: OpenAI;

  constructor(apiKey: string, baseURL?: string) {
    this.client = new OpenAI({
      apiKey,
      baseURL: baseURL ?? DEFAULT_BASE_URL,
    });
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

    const reasoning = isReasoningModel(model);

    // Build message list (prepend system if provided)
    const allMessages: Message[] = system
      ? [{ role: "system", content: [{ type: "text", text: system }] }, ...messages]
      : messages;

    const openaiMessages = translateMessages(allMessages);

    // Build request params
    const params: Record<string, unknown> = {
      model,
      messages: openaiMessages,
      stream: true,
      stream_options: { include_usage: true },
    };

    if (maxTokens !== undefined) params.max_tokens = maxTokens;

    // Reasoning models reject temperature and top_p
    if (!reasoning) {
      if (temperature !== undefined) params.temperature = temperature;
      if (topP !== undefined) params.top_p = topP;
    }

    if (stopSequences && stopSequences.length > 0) params.stop = stopSequences;

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
        { signal: abortSignal },
      );
    } catch (err) {
      throw this.wrapError(err);
    }

    const toolCallAccumulator: Map<number, { id: string; name: string; args: string }> = new Map();

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
            if (delta.content) {
              yield { kind: "text_delta", text: delta.content };
            }

            if (delta.tool_calls) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index;
                if (!toolCallAccumulator.has(idx)) {
                  const id = tc.id ?? "";
                  const name = tc.function?.name ?? "";
                  toolCallAccumulator.set(idx, { id, name, args: "" });
                  yield { kind: "tool_call_start", id, name };
                }

                const entry = toolCallAccumulator.get(idx)!;
                if (tc.id && !entry.id) entry.id = tc.id;
                if (tc.function?.name && !entry.name) entry.name = tc.function.name;

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

    for (const [, entry] of toolCallAccumulator) {
      let input: unknown;
      try {
        input = JSON.parse(entry.args);
      } catch {
        input = {};
      }
      yield { kind: "tool_call_end", id: entry.id, input };
    }

    yield { kind: "message_stop", reason: mapFinishReason(finishReason) };
  }

  private wrapError(err: unknown): ProviderError {
    if (err instanceof OpenAI.APIError) {
      return new ProviderError(err.message, this.id, err.status, isRetryable(err.status), err);
    }
    if (err instanceof ProviderError) return err;
    const msg = err instanceof Error ? err.message : String(err);
    return new ProviderError(msg, this.id, undefined, false, err);
  }
}

// ---------------------------------------------------------------------------
// DashScopeProviderFactory
// ---------------------------------------------------------------------------

export const DashScopeProviderFactory: ProviderFactory = {
  id: "dashscope",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    const apiKey = env["DASHSCOPE_API_KEY"];
    if (!apiKey) return null;
    return new DashScopeProvider(apiKey, env["DASHSCOPE_BASE_URL"]);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const apiKey = config["apiKey"];
    if (typeof apiKey !== "string" || !apiKey) {
      throw new Error("dashscope config requires apiKey");
    }
    return new DashScopeProvider(apiKey, config["baseURL"] as string | undefined);
  },
};
