import type { EndpointClass, Usage } from "./types";

export const ZERO_ESTIMATED_USAGE: Usage = {
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  estimated: true,
};

export function parseJsonUsage(endpointClass: EndpointClass, payload: unknown): Usage {
  const record = asRecord(payload);
  if (!record) return { ...ZERO_ESTIMATED_USAGE };
  if (endpointClass === "anthropic") {
    const usage = asRecord(record.usage);
    return usage
      ? {
          inputTokens: numberValue(usage.input_tokens),
          outputTokens: numberValue(usage.output_tokens),
          cacheReadTokens: numberValue(usage.cache_read_input_tokens),
          cacheWriteTokens: numberValue(usage.cache_creation_input_tokens),
          estimated: false,
        }
      : { ...ZERO_ESTIMATED_USAGE };
  }
  const usage = asRecord(record.usage) ?? asRecord(asRecord(record.response)?.usage);
  if (!usage) return { ...ZERO_ESTIMATED_USAGE };
  const details = asRecord(usage.input_tokens_details);
  return {
    inputTokens: numberValue(usage.input_tokens) || numberValue(usage.prompt_tokens),
    outputTokens: numberValue(usage.output_tokens) || numberValue(usage.completion_tokens),
    cacheReadTokens: numberValue(details?.cached_tokens),
    cacheWriteTokens: 0,
    estimated: false,
  };
}

export function parseSseUsage(endpointClass: EndpointClass, text: string): Usage {
  const scanner = new SseUsageScanner(endpointClass);
  scanner.pushText(text);
  return scanner.finish();
}

export async function drainSseUsage(endpointClass: EndpointClass, stream: ReadableStream<Uint8Array> | null): Promise<Usage> {
  if (!stream) return { ...ZERO_ESTIMATED_USAGE };
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const scanner = new SseUsageScanner(endpointClass);
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      scanner.pushText(decoder.decode(chunk.value, { stream: true }));
    }
    scanner.pushText(decoder.decode());
  } catch {
    return { ...ZERO_ESTIMATED_USAGE };
  }
  return scanner.finish();
}

export class SseUsageScanner {
  private partialLine = "";
  private currentEvent: string | null = null;
  private usage: Usage = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, estimated: true };
  private sawUsage = false;
  maxRetainedLineLength = 0;

  constructor(private readonly endpointClass: EndpointClass) {}

  pushText(text: string): void {
    if (!text) return;
    const combined = this.partialLine + text;
    const lines = combined.split("\n");
    this.partialLine = lines.pop() ?? "";
    this.maxRetainedLineLength = Math.max(this.maxRetainedLineLength, this.partialLine.length);
    for (const rawLine of lines) {
      this.processLine(rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine);
    }
  }

  finish(): Usage {
    if (this.partialLine) {
      this.processLine(this.partialLine);
      this.partialLine = "";
    }
    this.usage.estimated = !this.sawUsage;
    return { ...this.usage };
  }

  private processLine(line: string): void {
    if (line.length === 0) {
      this.currentEvent = null;
      return;
    }
    if (line.startsWith("event:")) {
      this.currentEvent = line.slice(6).trim();
      return;
    }
    if (!line.startsWith("data:")) return;
    const data = line.slice(5).trimStart();
    if (!data || data === "[DONE]") return;
    const payload = parseJson(data);
    if (!payload) return;
    if (this.endpointClass === "anthropic") this.applyAnthropicPayload(this.currentEvent, payload);
    else this.applyOpenAiPayload(this.currentEvent, payload);
  }

  private applyAnthropicPayload(event: string | null, payload: unknown): void {
    if (event === "message_start") {
      const record = asRecord(payload);
      const startUsage = asRecord(asRecord(record?.message)?.usage);
      if (startUsage) {
        this.usage.inputTokens = numberValue(startUsage.input_tokens);
        this.usage.cacheWriteTokens = numberValue(startUsage.cache_creation_input_tokens);
        this.usage.cacheReadTokens = numberValue(startUsage.cache_read_input_tokens);
        this.sawUsage = true;
      }
    }
    if (event === "message_delta") {
      const record = asRecord(payload);
      const deltaUsage = asRecord(record?.usage);
      if (deltaUsage) {
        this.usage.outputTokens = numberValue(deltaUsage.output_tokens);
        this.sawUsage = true;
      }
    }
  }

  private applyOpenAiPayload(event: string | null, payload: unknown): void {
    if (event === "response.completed") {
      this.usage = parseJsonUsage("openai_api", asRecord(payload)?.response);
      this.sawUsage = !this.usage.estimated;
    } else {
      const record = asRecord(payload);
      if (record?.usage) {
        this.usage = parseJsonUsage("openai_api", record);
        this.sawUsage = !this.usage.estimated;
      }
    }
  }
}

function parseJson(text: string): unknown | null {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
