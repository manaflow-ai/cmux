/**
 * OpenRouter provider adapter.
 *
 * OpenRouter exposes an OpenAI-compatible chat completions API at
 * https://openrouter.ai/api/v1. This adapter translates between the canonical
 * cmux101 types and the OpenAI SDK, passing the required OpenRouter headers.
 */

import OpenAI from "openai";
import type {
  Provider,
  ProviderFactory,
  ProviderRequest,
  StreamEvent,
  ModelInfo,
  StopReason,
} from "../core/types.js";
import { ProviderError } from "../core/types.js";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const BASE_URL = "https://openrouter.ai/api/v1";
const CACHE_TTL_MS = 10 * 60 * 1000; // 10 minutes

const FALLBACK_MODELS: ModelInfo[] = [
  {
    id: "anthropic/claude-opus-4.7",
    displayName: "Claude Opus 4.7",
    contextWindow: 200_000,
    maxOutput: 4096,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "openai/gpt-4o",
    displayName: "GPT-4o",
    contextWindow: 128_000,
    maxOutput: 4096,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "google/gemini-2.5-pro",
    displayName: "Gemini 2.5 Pro",
    contextWindow: 1_000_000,
    maxOutput: 8192,
    supportsTools: true,
    supportsVision: true,
    supportsThinking: false,
  },
  {
    id: "meta-llama/llama-3.1-405b",
    displayName: "Llama 3.1 405B",
    contextWindow: 128_000,
    maxOutput: 4096,
    supportsTools: true,
    supportsVision: false,
    supportsThinking: false,
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function mapStopReason(
  finish_reason: string | null | undefined,
): StopReason {
  switch (finish_reason) {
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
// OpenRouterProvider
// ---------------------------------------------------------------------------

export class OpenRouterProvider implements Provider {
  readonly id = "openrouter";
  readonly displayName = "OpenRouter";

  private client: OpenAI;
  private modelCache: { models: ModelInfo[]; fetchedAt: number } | null = null;

  constructor(apiKey: string) {
    this.client = new OpenAI({
      apiKey,
      baseURL: BASE_URL,
      defaultHeaders: {
        "HTTP-Referer": "https://github.com/manaflow-ai/cmux",
        "X-Title": "cmux101",
      },
    });
  }

  async listModels(): Promise<ModelInfo[]> {
    const now = Date.now();
    if (this.modelCache && now - this.modelCache.fetchedAt < CACHE_TTL_MS) {
      return this.modelCache.models;
    }

    try {
      const response = await fetch(`${BASE_URL}/models`, {
        headers: {
          Authorization: `Bearer ${(this.client as unknown as { apiKey: string }).apiKey}`,
          "HTTP-Referer": "https://github.com/manaflow-ai/cmux",
          "X-Title": "cmux101",
        },
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = (await response.json()) as {
        data?: Array<{
          id: string;
          name?: string;
          context_length?: number;
          top_provider?: { max_completion_tokens?: number };
          architecture?: { modality?: string };
          supported_parameters?: string[];
        }>;
      };

      const models: ModelInfo[] = (data.data ?? []).map((m) => {
        const modality = m.architecture?.modality ?? "";
        const supportsVision =
          modality.includes("image") || modality.includes("multimodal");
        const supportsTools =
          m.supported_parameters?.includes("tools") ?? true;

        return {
          id: m.id,
          displayName: m.name ?? m.id,
          contextWindow: m.context_length ?? 4096,
          maxOutput: m.top_provider?.max_completion_tokens ?? 4096,
          supportsTools,
          supportsVision,
          supportsThinking: false,
        };
      });

      this.modelCache = { models, fetchedAt: now };
      return models;
    } catch {
      // Return hardcoded fallback list on any failure
      return FALLBACK_MODELS;
    }
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    // Build messages array
    const messages: OpenAI.ChatCompletionMessageParam[] = [];

    if (request.system) {
      messages.push({ role: "system", content: request.system });
    }

    for (const msg of request.messages) {
      if (msg.role === "system") {
        messages.push({ role: "system", content: msg.content
          .filter((b) => b.type === "text")
          .map((b) => (b as { type: "text"; text: string }).text)
          .join("\n") });
        continue;
      }

      if (msg.role === "user") {
        const parts: OpenAI.ChatCompletionContentPart[] = [];
        for (const block of msg.content) {
          if (block.type === "text") {
            parts.push({ type: "text", text: block.text });
          } else if (block.type === "image") {
            if (block.source.kind === "url") {
              parts.push({ type: "image_url", image_url: { url: block.source.url } });
            } else if (block.source.kind === "base64") {
              parts.push({
                type: "image_url",
                image_url: {
                  url: `data:${block.source.mediaType};base64,${block.source.data}`,
                },
              });
            }
          } else if (block.type === "tool_result") {
            // Tool results for user role are handled below
          }
        }
        // Check for tool_result blocks — these become "tool" role messages
        const toolResults = msg.content.filter((b) => b.type === "tool_result");
        for (const tr of toolResults) {
          const trBlock = tr as {
            type: "tool_result";
            tool_use_id: string;
            content: string | Array<{ type: "text"; text: string } | { type: "image" }>;
          };
          const content =
            typeof trBlock.content === "string"
              ? trBlock.content
              : trBlock.content
                  .filter((c) => c.type === "text")
                  .map((c) => (c as { type: "text"; text: string }).text)
                  .join("\n");
          messages.push({
            role: "tool",
            tool_call_id: trBlock.tool_use_id,
            content,
          });
        }
        if (parts.length > 0) {
          messages.push({ role: "user", content: parts.length === 1 && parts[0].type === "text" ? parts[0].text : parts });
        }
        continue;
      }

      if (msg.role === "assistant") {
        const textParts = msg.content.filter((b) => b.type === "text");
        const toolUseParts = msg.content.filter((b) => b.type === "tool_use");
        const text = textParts.map((b) => (b as { type: "text"; text: string }).text).join("");
        const toolCalls: OpenAI.ChatCompletionMessageToolCall[] = toolUseParts.map((b) => {
          const tu = b as { type: "tool_use"; id: string; name: string; input: unknown };
          return {
            id: tu.id,
            type: "function" as const,
            function: {
              name: tu.name,
              arguments: JSON.stringify(tu.input),
            },
          };
        });
        const assistantMsg: OpenAI.ChatCompletionAssistantMessageParam = {
          role: "assistant",
          content: text || null,
        };
        if (toolCalls.length > 0) {
          assistantMsg.tool_calls = toolCalls;
        }
        messages.push(assistantMsg);
        continue;
      }

      if (msg.role === "tool") {
        for (const block of msg.content) {
          if (block.type === "tool_result") {
            const trBlock = block as {
              type: "tool_result";
              tool_use_id: string;
              content: string | Array<{ type: "text"; text: string } | { type: "image" }>;
            };
            const content =
              typeof trBlock.content === "string"
                ? trBlock.content
                : trBlock.content
                    .filter((c) => c.type === "text")
                    .map((c) => (c as { type: "text"; text: string }).text)
                    .join("\n");
            messages.push({
              role: "tool",
              tool_call_id: trBlock.tool_use_id,
              content,
            });
          }
        }
        continue;
      }
    }

    // Build tools array
    const tools: OpenAI.ChatCompletionTool[] | undefined =
      request.tools && request.tools.length > 0
        ? request.tools.map((t) => ({
            type: "function" as const,
            function: {
              name: t.name,
              description: t.description,
              parameters: t.inputSchema as Record<string, unknown>,
            },
          }))
        : undefined;

    const body: OpenAI.ChatCompletionCreateParamsStreaming = {
      model: request.model,
      messages,
      stream: true,
      max_tokens: request.maxTokens,
      temperature: request.temperature,
      top_p: request.topP,
      stop: request.stopSequences,
      tools,
    };

    // Remove undefined keys
    for (const key of Object.keys(body) as (keyof typeof body)[]) {
      if (body[key] === undefined) {
        delete body[key];
      }
    }

    let streamInstance: AsyncIterable<OpenAI.Chat.Completions.ChatCompletionChunk>;
    try {
      streamInstance = await this.client.chat.completions.create(body, {
        signal: request.abortSignal,
      });
    } catch (err: unknown) {
      const status = (err as { status?: number }).status;
      throw new ProviderError(
        `OpenRouter request failed: ${String(err)}`,
        this.id,
        status,
        status === 429 || (status !== undefined && status >= 500),
        err,
      );
    }

    // Emit a synthetic message_start
    const messageId = `or_${Date.now()}`;
    yield { kind: "message_start", messageId };

    // Track partial tool call accumulation
    const toolCallAccumulator = new Map<
      number,
      { id: string; name: string; jsonDelta: string }
    >();

    let finishReason: string | null | undefined;

    try {
      for await (const chunk of streamInstance) {
        const choice = chunk.choices?.[0];
        if (!choice) {
          // Check for usage-only chunk
          if (chunk.usage) {
            yield {
              kind: "usage",
              inputTokens: chunk.usage.prompt_tokens ?? 0,
              outputTokens: chunk.usage.completion_tokens ?? 0,
            };
          }
          continue;
        }

        const delta = choice.delta;
        finishReason = choice.finish_reason ?? finishReason;

        // Text delta
        if (delta.content) {
          yield { kind: "text_delta", text: delta.content };
        }

        // Tool calls
        if (delta.tool_calls) {
          for (const tc of delta.tool_calls) {
            const idx = tc.index;
            if (tc.id) {
              // First chunk for this tool call
              toolCallAccumulator.set(idx, {
                id: tc.id,
                name: tc.function?.name ?? "",
                jsonDelta: tc.function?.arguments ?? "",
              });
              yield { kind: "tool_call_start", id: tc.id, name: tc.function?.name ?? "" };
            } else {
              const acc = toolCallAccumulator.get(idx);
              if (acc) {
                const argDelta = tc.function?.arguments ?? "";
                acc.jsonDelta += argDelta;
                if (argDelta) {
                  yield { kind: "tool_call_input_delta", id: acc.id, jsonDelta: argDelta };
                }
                // Update name if we get it late
                if (tc.function?.name) {
                  acc.name += tc.function.name;
                }
              }
            }
          }
        }

        // Usage
        if (chunk.usage) {
          yield {
            kind: "usage",
            inputTokens: chunk.usage.prompt_tokens ?? 0,
            outputTokens: chunk.usage.completion_tokens ?? 0,
          };
        }
      }
    } catch (err: unknown) {
      const status = (err as { status?: number }).status;
      yield {
        kind: "error",
        error: new ProviderError(
          `OpenRouter stream error: ${String(err)}`,
          this.id,
          status,
          status === 429 || (status !== undefined && status >= 500),
          err,
        ),
      };
      return;
    }

    // Emit tool_call_end for all accumulated tool calls
    for (const [, acc] of toolCallAccumulator) {
      let parsedInput: unknown = {};
      try {
        parsedInput = JSON.parse(acc.jsonDelta);
      } catch {
        parsedInput = acc.jsonDelta;
      }
      yield { kind: "tool_call_end", id: acc.id, input: parsedInput };
    }

    yield { kind: "message_stop", reason: mapStopReason(finishReason) };
  }
}

// ---------------------------------------------------------------------------
// OpenRouterProviderFactory
// ---------------------------------------------------------------------------

export const OpenRouterProviderFactory: ProviderFactory = {
  id: "openrouter",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    const apiKey = env["OPENROUTER_API_KEY"];
    if (!apiKey) return null;
    return new OpenRouterProvider(apiKey);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const apiKey = config["apiKey"];
    if (typeof apiKey !== "string" || !apiKey) {
      throw new Error("openrouter config requires apiKey");
    }
    return new OpenRouterProvider(apiKey);
  },
};
