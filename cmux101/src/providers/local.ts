/**
 * Local provider adapters: Ollama and LM Studio.
 *
 * Both expose an OpenAI-compatible chat completions API. This module provides
 * two provider classes that share streaming/message-translation logic via a
 * private base class.
 *
 * NOTE: fromEnv() always returns an instance. listModels() / stream() will
 * throw a ProviderError if the local server is not reachable.
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
// Defaults & constants
// ---------------------------------------------------------------------------

const OLLAMA_DEFAULT_BASE_URL = "http://localhost:11434/v1";
const LMSTUDIO_DEFAULT_BASE_URL = "http://localhost:1234/v1";
const CACHE_TTL_MS = 60 * 1000; // 60 seconds

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function mapStopReason(finish_reason: string | null | undefined): StopReason {
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

/**
 * Determine whether a model likely supports tool calling based on its name.
 * This is a heuristic — Ollama does not report capabilities in /api/tags.
 */
function supportsToolsHeuristic(modelName: string): boolean {
  const name = modelName.toLowerCase();
  return (
    name.includes("llama3") ||
    name.includes("llama-3") ||
    name.includes("qwen2.5") ||
    name.includes("qwen2_5") ||
    name.includes("mistral") ||
    name.includes("mixtral") ||
    name.includes("command-r") ||
    name.includes("hermes")
  );
}

// ---------------------------------------------------------------------------
// Shared message translation
// ---------------------------------------------------------------------------

function buildOpenAIMessages(
  request: ProviderRequest,
): OpenAI.ChatCompletionMessageParam[] {
  const messages: OpenAI.ChatCompletionMessageParam[] = [];

  if (request.system) {
    messages.push({ role: "system", content: request.system });
  }

  for (const msg of request.messages) {
    if (msg.role === "system") {
      messages.push({
        role: "system",
        content: msg.content
          .filter((b) => b.type === "text")
          .map((b) => (b as { type: "text"; text: string }).text)
          .join("\n"),
      });
      continue;
    }

    if (msg.role === "user") {
      // Separate tool_result blocks (these become "tool" role messages)
      const toolResults = msg.content.filter((b) => b.type === "tool_result");
      for (const tr of toolResults) {
        const trBlock = tr as {
          type: "tool_result";
          tool_use_id: string;
          content:
            | string
            | Array<{ type: "text"; text: string } | { type: "image" }>;
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

      const parts: OpenAI.ChatCompletionContentPart[] = [];
      for (const block of msg.content) {
        if (block.type === "text") {
          parts.push({ type: "text", text: block.text });
        } else if (block.type === "image") {
          if (block.source.kind === "url") {
            parts.push({
              type: "image_url",
              image_url: { url: block.source.url },
            });
          } else if (block.source.kind === "base64") {
            parts.push({
              type: "image_url",
              image_url: {
                url: `data:${block.source.mediaType};base64,${block.source.data}`,
              },
            });
          }
        }
        // tool_result handled above
      }

      if (parts.length > 0) {
        messages.push({
          role: "user",
          content:
            parts.length === 1 && parts[0].type === "text"
              ? parts[0].text
              : parts,
        });
      }
      continue;
    }

    if (msg.role === "assistant") {
      const textParts = msg.content.filter((b) => b.type === "text");
      const toolUseParts = msg.content.filter((b) => b.type === "tool_use");
      const text = textParts
        .map((b) => (b as { type: "text"; text: string }).text)
        .join("");
      const toolCalls: OpenAI.ChatCompletionMessageToolCall[] =
        toolUseParts.map((b) => {
          const tu = b as {
            type: "tool_use";
            id: string;
            name: string;
            input: unknown;
          };
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
            content:
              | string
              | Array<{ type: "text"; text: string } | { type: "image" }>;
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

  return messages;
}

// ---------------------------------------------------------------------------
// Base class for local OpenAI-compatible providers
// ---------------------------------------------------------------------------

abstract class LocalOpenAIProvider implements Provider {
  abstract readonly id: string;
  abstract readonly displayName: string;

  protected client: OpenAI;
  protected baseUrl: string;
  protected modelCache: { models: ModelInfo[]; fetchedAt: number } | null =
    null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
    this.client = new OpenAI({
      apiKey: "local", // dummy key — local servers don't validate
      baseURL: baseUrl,
    });
  }

  abstract listModels(): Promise<ModelInfo[]>;

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const messages = buildOpenAIMessages(request);

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
        `${this.displayName} request failed: ${String(err)}`,
        this.id,
        status,
        false,
        err,
      );
    }

    const messageId = `local_${Date.now()}`;
    yield { kind: "message_start", messageId };

    const toolCallAccumulator = new Map<
      number,
      { id: string; name: string; jsonDelta: string }
    >();

    let finishReason: string | null | undefined;

    try {
      for await (const chunk of streamInstance) {
        const choice = chunk.choices?.[0];
        if (!choice) {
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

        if (delta.content) {
          yield { kind: "text_delta", text: delta.content };
        }

        if (delta.tool_calls) {
          for (const tc of delta.tool_calls) {
            const idx = tc.index;
            if (tc.id) {
              toolCallAccumulator.set(idx, {
                id: tc.id,
                name: tc.function?.name ?? "",
                jsonDelta: tc.function?.arguments ?? "",
              });
              yield {
                kind: "tool_call_start",
                id: tc.id,
                name: tc.function?.name ?? "",
              };
            } else {
              const acc = toolCallAccumulator.get(idx);
              if (acc) {
                const argDelta = tc.function?.arguments ?? "";
                acc.jsonDelta += argDelta;
                if (argDelta) {
                  yield {
                    kind: "tool_call_input_delta",
                    id: acc.id,
                    jsonDelta: argDelta,
                  };
                }
                if (tc.function?.name) {
                  acc.name += tc.function.name;
                }
              }
            }
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
    } catch (err: unknown) {
      const status = (err as { status?: number }).status;
      yield {
        kind: "error",
        error: new ProviderError(
          `${this.displayName} stream error: ${String(err)}`,
          this.id,
          status,
          false,
          err,
        ),
      };
      return;
    }

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
// OllamaProvider
// ---------------------------------------------------------------------------

/**
 * Provider for Ollama.
 *
 * listModels() calls Ollama's native /api/tags endpoint, which is more
 * reliable than /v1/models. The base URL for that call strips the /v1 suffix.
 */
export class OllamaProvider extends LocalOpenAIProvider {
  readonly id = "ollama";
  readonly displayName = "Ollama";

  /** The host root without /v1 (used to call /api/tags). */
  private hostRoot: string;

  constructor(baseUrl: string = OLLAMA_DEFAULT_BASE_URL) {
    super(baseUrl);
    // Strip trailing /v1 to get the Ollama host root
    this.hostRoot = baseUrl.replace(/\/v1\/?$/, "");
  }

  async listModels(): Promise<ModelInfo[]> {
    const now = Date.now();
    if (this.modelCache && now - this.modelCache.fetchedAt < CACHE_TTL_MS) {
      return this.modelCache.models;
    }

    const response = await fetch(`${this.hostRoot}/api/tags`).catch((err) => {
      throw new ProviderError(
        `Ollama not reachable at ${this.hostRoot}: ${String(err)}`,
        this.id,
        undefined,
        false,
        err,
      );
    });

    if (!response.ok) {
      throw new ProviderError(
        `Ollama /api/tags returned HTTP ${response.status}`,
        this.id,
        response.status,
        false,
      );
    }

    const data = (await response.json()) as {
      models?: Array<{
        name: string;
        details?: {
          parameter_size?: string;
          family?: string;
          families?: string[];
        };
      }>;
    };

    const models: ModelInfo[] = (data.models ?? []).map((m) => {
      const supportsTools = supportsToolsHeuristic(m.name);
      // Conservatively assume 32k context, 4k output for local models
      return {
        id: m.name,
        displayName: m.name,
        contextWindow: 32_768,
        maxOutput: 4096,
        supportsTools,
        supportsVision: false,
        supportsThinking: false,
      };
    });

    this.modelCache = { models, fetchedAt: now };
    return models;
  }
}

// ---------------------------------------------------------------------------
// LMStudioProvider
// ---------------------------------------------------------------------------

/**
 * Provider for LM Studio.
 *
 * listModels() calls LM Studio's /v1/models endpoint and reports whatever
 * the server returns.
 */
export class LMStudioProvider extends LocalOpenAIProvider {
  readonly id = "lmstudio";
  readonly displayName = "LM Studio";

  constructor(baseUrl: string = LMSTUDIO_DEFAULT_BASE_URL) {
    super(baseUrl);
  }

  async listModels(): Promise<ModelInfo[]> {
    const now = Date.now();
    if (this.modelCache && now - this.modelCache.fetchedAt < CACHE_TTL_MS) {
      return this.modelCache.models;
    }

    const response = await fetch(`${this.baseUrl}/models`).catch((err) => {
      throw new ProviderError(
        `LM Studio not reachable at ${this.baseUrl}: ${String(err)}`,
        this.id,
        undefined,
        false,
        err,
      );
    });

    if (!response.ok) {
      throw new ProviderError(
        `LM Studio /v1/models returned HTTP ${response.status}`,
        this.id,
        response.status,
        false,
      );
    }

    const data = (await response.json()) as {
      data?: Array<{
        id: string;
        context_window?: number;
        max_context_length?: number;
      }>;
    };

    const models: ModelInfo[] = (data.data ?? []).map((m) => ({
      id: m.id,
      displayName: m.id,
      contextWindow: m.context_window ?? m.max_context_length ?? 32_768,
      maxOutput: 4096,
      supportsTools: supportsToolsHeuristic(m.id),
      supportsVision: false,
      supportsThinking: false,
    }));

    this.modelCache = { models, fetchedAt: now };
    return models;
  }
}

// ---------------------------------------------------------------------------
// Factories
// ---------------------------------------------------------------------------

export const OllamaProviderFactory: ProviderFactory = {
  id: "ollama",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    // Always return an instance — listModels()/stream() will surface errors if
    // Ollama is not running. Callers can catch ProviderError to handle gracefully.
    const baseUrl = env["OLLAMA_BASE_URL"] ?? OLLAMA_DEFAULT_BASE_URL;
    return new OllamaProvider(baseUrl);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const baseUrl =
      typeof config["baseUrl"] === "string"
        ? config["baseUrl"]
        : OLLAMA_DEFAULT_BASE_URL;
    return new OllamaProvider(baseUrl);
  },
};

export const LMStudioProviderFactory: ProviderFactory = {
  id: "lmstudio",

  fromEnv(env: NodeJS.ProcessEnv): Provider | null {
    // Always return an instance — see OllamaProviderFactory note above.
    const baseUrl = env["LMSTUDIO_BASE_URL"] ?? LMSTUDIO_DEFAULT_BASE_URL;
    return new LMStudioProvider(baseUrl);
  },

  fromConfig(config: Record<string, unknown>): Provider {
    const baseUrl =
      typeof config["baseUrl"] === "string"
        ? config["baseUrl"]
        : LMSTUDIO_DEFAULT_BASE_URL;
    return new LMStudioProvider(baseUrl);
  },
};
