/**
 * Google Gemini provider adapter for cmux101.
 *
 * Maps cmux101's canonical Provider interface onto the @google/generative-ai SDK.
 */

import {
  GoogleGenerativeAI,
  GoogleGenerativeAIFetchError,
  type Content,
  type Part,
  type FunctionDeclaration,
} from "@google/generative-ai";

import type {
  Provider,
  ProviderFactory,
  ProviderRequest,
  StreamEvent,
  ModelInfo,
  Message,
  ContentBlock,
  ToolSchema,
  StopReason,
} from "../core/types.js";

import { ProviderError } from "../core/types.js";

// ---------------------------------------------------------------------------
// JSON-Schema stripping
// ---------------------------------------------------------------------------

/** Fields that Gemini's FunctionDeclaration schema does not accept. */
const STRIP_KEYS = new Set(["$schema", "additionalProperties"]);

function stripUnsupportedSchemaFields(obj: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (STRIP_KEYS.has(key)) continue;
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      result[key] = stripUnsupportedSchemaFields(value as Record<string, unknown>);
    } else if (Array.isArray(value)) {
      result[key] = value.map((item) =>
        item !== null && typeof item === "object"
          ? stripUnsupportedSchemaFields(item as Record<string, unknown>)
          : item
      );
    } else {
      result[key] = value;
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Message translation
// ---------------------------------------------------------------------------

/**
 * Scan a sequence of messages and build a map of tool_use_id -> tool_name.
 * Gemini tool_result (functionResponse) needs the name, but cmux101's
 * ToolResultBlock only has the id.
 */
function buildToolUseIdMap(messages: Message[]): Map<string, string> {
  const map = new Map<string, string>();
  for (const msg of messages) {
    for (const block of msg.content) {
      if (block.type === "tool_use") {
        map.set(block.id, block.name);
      }
    }
  }
  return map;
}

function contentBlocksToParts(
  blocks: ContentBlock[],
  toolIdToName: Map<string, string>
): Part[] {
  const parts: Part[] = [];

  for (const block of blocks) {
    switch (block.type) {
      case "text":
        parts.push({ text: block.text });
        break;

      case "tool_use":
        // assistant -> functionCall
        parts.push({
          functionCall: {
            name: block.name,
            args: block.input as object,
          },
        });
        break;

      case "tool_result": {
        // user/tool -> functionResponse
        const toolName = toolIdToName.get(block.tool_use_id) ?? block.tool_use_id;
        let content: string;
        if (typeof block.content === "string") {
          content = block.content;
        } else {
          content = block.content
            .map((c) => (c.type === "text" ? c.text : `[image]`))
            .join("\n");
        }
        parts.push({
          functionResponse: {
            name: toolName,
            response: { content },
          },
        });
        break;
      }

      case "image":
        if (block.source.kind === "base64") {
          parts.push({
            inlineData: {
              mimeType: block.source.mediaType,
              data: block.source.data,
            },
          });
        } else {
          parts.push({
            fileData: {
              mimeType: "image/jpeg", // best-effort; URL images rarely carry mime
              fileUri: block.source.url,
            },
          });
        }
        break;

      case "thinking":
        // Drop silently — Gemini doesn't round-trip thinking blocks
        break;

      default:
        // Exhaustiveness guard — unknown future block types are dropped
        break;
    }
  }

  return parts;
}

/**
 * Translate cmux101 Messages into Gemini Contents.
 *
 * Rules:
 *  - "system" messages are extracted separately and NOT included here.
 *  - "assistant" role -> "model"
 *  - "tool" role -> "user" (functionResponse lives in a user turn)
 */
function messagesToContents(messages: Message[]): Content[] {
  const toolIdToName = buildToolUseIdMap(messages);
  const contents: Content[] = [];

  for (const msg of messages) {
    if (msg.role === "system") continue; // handled via systemInstruction

    const geminiRole =
      msg.role === "assistant"
        ? "model"
        : "user"; // covers both "user" and "tool"

    const parts = contentBlocksToParts(msg.content, toolIdToName);
    if (parts.length === 0) continue;

    contents.push({ role: geminiRole, parts });
  }

  return contents;
}

function extractSystemInstruction(messages: Message[]): string | undefined {
  const systemParts = messages
    .filter((m) => m.role === "system")
    .flatMap((m) =>
      m.content
        .filter((b) => b.type === "text")
        .map((b) => (b as { type: "text"; text: string }).text)
    );
  return systemParts.length > 0 ? systemParts.join("\n\n") : undefined;
}

// ---------------------------------------------------------------------------
// Tool schema translation
// ---------------------------------------------------------------------------

function toGeminiFunctionDeclarations(tools: ToolSchema[]): FunctionDeclaration[] {
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    parameters: stripUnsupportedSchemaFields(t.inputSchema) as unknown as FunctionDeclaration["parameters"],
  }));
}

// ---------------------------------------------------------------------------
// Finish-reason mapping
// ---------------------------------------------------------------------------

function mapFinishReason(
  geminiReason: string | undefined,
  hadFunctionCall: boolean
): StopReason {
  if (hadFunctionCall) return "tool_use";
  switch (geminiReason) {
    case "STOP":
      return "end_turn";
    case "MAX_TOKENS":
      return "max_tokens";
    case "SAFETY":
    case "RECITATION":
      return "refusal";
    default:
      return "end_turn";
  }
}

// ---------------------------------------------------------------------------
// Error wrapping
// ---------------------------------------------------------------------------

function wrapError(err: unknown): ProviderError {
  if (err instanceof ProviderError) return err;

  if (err instanceof GoogleGenerativeAIFetchError) {
    const retryable = err.status === 429;
    return new ProviderError(
      err.message,
      "gemini",
      err.status,
      retryable,
      err
    );
  }

  if (err instanceof Error) {
    return new ProviderError(err.message, "gemini", undefined, false, err);
  }

  return new ProviderError(String(err), "gemini", undefined, false, err);
}

// ---------------------------------------------------------------------------
// GeminiProvider
// ---------------------------------------------------------------------------

export class GeminiProvider implements Provider {
  readonly id = "gemini";
  readonly displayName = "Google Gemini";

  constructor(private readonly apiKey: string) {}

  async listModels(): Promise<ModelInfo[]> {
    return [
      {
        id: "gemini-2.5-pro",
        displayName: "Gemini 2.5 Pro",
        contextWindow: 1_048_576,
        maxOutput: 65_536,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "gemini-2.5-flash",
        displayName: "Gemini 2.5 Flash",
        contextWindow: 1_048_576,
        maxOutput: 65_536,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: true,
      },
      {
        id: "gemini-2.0-flash",
        displayName: "Gemini 2.0 Flash",
        contextWindow: 1_048_576,
        maxOutput: 8_192,
        supportsTools: true,
        supportsVision: true,
        supportsThinking: false,
      },
    ];
  }

  async *stream(request: ProviderRequest): AsyncIterable<StreamEvent> {
    const genAI = new GoogleGenerativeAI(this.apiKey);

    const systemText =
      request.system ?? extractSystemInstruction(request.messages);

    const modelParams: Parameters<typeof genAI.getGenerativeModel>[0] = {
      model: request.model,
      ...(systemText ? { systemInstruction: systemText } : {}),
      generationConfig: {
        ...(request.maxTokens != null ? { maxOutputTokens: request.maxTokens } : {}),
        ...(request.temperature != null ? { temperature: request.temperature } : {}),
        ...(request.topP != null ? { topP: request.topP } : {}),
        ...(request.stopSequences?.length ? { stopSequences: request.stopSequences } : {}),
      },
      ...(request.tools?.length
        ? {
            tools: [
              {
                functionDeclarations: toGeminiFunctionDeclarations(request.tools),
              },
            ],
          }
        : {}),
    };

    const model = genAI.getGenerativeModel(modelParams);
    const contents = messagesToContents(request.messages);

    let streamResult: Awaited<ReturnType<typeof model.generateContentStream>>;
    try {
      streamResult = await model.generateContentStream(
        { contents },
        request.abortSignal ? { signal: request.abortSignal } : undefined
      );
    } catch (err) {
      const wrapped = wrapError(err);
      yield { kind: "error", error: wrapped };
      return;
    }

    // Emit message_start with a synthetic id
    const messageId = `gemini-${Date.now()}`;
    yield { kind: "message_start", messageId };

    let toolCallCounter = 0;
    let lastFinishReason: string | undefined;
    let hadFunctionCall = false;
    let lastUsage: { inputTokens: number; outputTokens: number } | undefined;

    try {
      for await (const chunk of streamResult.stream) {
        // Capture usage from every chunk; last one wins
        if (chunk.usageMetadata) {
          lastUsage = {
            inputTokens: chunk.usageMetadata.promptTokenCount ?? 0,
            outputTokens: chunk.usageMetadata.candidatesTokenCount ?? 0,
          };
        }

        const candidate = chunk.candidates?.[0];
        if (!candidate) continue;

        if (candidate.finishReason) {
          lastFinishReason = candidate.finishReason;
        }

        const parts = candidate.content?.parts ?? [];
        for (const part of parts) {
          if (part.text !== undefined) {
            yield { kind: "text_delta", text: part.text };
          } else if ("functionCall" in part && part.functionCall) {
            hadFunctionCall = true;
            const fc = part.functionCall;
            const callId = `call_${++toolCallCounter}`;
            yield { kind: "tool_call_start", id: callId, name: fc.name };
            const argsJson = JSON.stringify(fc.args ?? {});
            yield { kind: "tool_call_input_delta", id: callId, jsonDelta: argsJson };
            yield { kind: "tool_call_end", id: callId, input: fc.args ?? {} };
          }
          // Other part types (codeExecutionResult, etc.) are silently skipped
        }
      }
    } catch (err) {
      const wrapped = wrapError(err);
      yield { kind: "error", error: wrapped };
      return;
    }

    if (lastUsage) {
      yield { kind: "usage", inputTokens: lastUsage.inputTokens, outputTokens: lastUsage.outputTokens };
    }

    const stopReason = mapFinishReason(lastFinishReason, hadFunctionCall);
    yield { kind: "message_stop", reason: stopReason };
  }
}

// ---------------------------------------------------------------------------
// GeminiProviderFactory
// ---------------------------------------------------------------------------

export const GeminiProviderFactory: ProviderFactory = {
  id: "gemini",

  fromEnv(env: NodeJS.ProcessEnv): GeminiProvider | null {
    const apiKey = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"];
    if (!apiKey) return null;
    return new GeminiProvider(apiKey);
  },

  fromConfig(config: Record<string, unknown>): GeminiProvider {
    const apiKey = config["apiKey"];
    if (typeof apiKey !== "string" || !apiKey) {
      throw new ProviderError(
        "GeminiProviderFactory.fromConfig: missing apiKey",
        "gemini"
      );
    }
    return new GeminiProvider(apiKey);
  },
};
