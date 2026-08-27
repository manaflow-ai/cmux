export type ModelUsage = {
  readonly model?: string;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
};

const MAX_TAIL_CHARS = 256 * 1024;

/**
 * Passes upstream bytes through immediately while retaining only a bounded
 * rolling tail and a model identifier. No prompt or model output is logged,
 * persisted, or sent to analytics.
 */
export function observeModelUsage(
  body: ReadableStream<Uint8Array> | null,
  onComplete: (usage: ModelUsage | null) => void,
): ReadableStream<Uint8Array> | null {
  if (!body) {
    onComplete(null);
    return null;
  }
  const decoder = new TextDecoder();
  let tail = "";
  let model: string | undefined;
  return body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        controller.enqueue(chunk);
        const text = decoder.decode(chunk, { stream: true });
        const combined = `${tail.slice(-256)}${text}`;
        model ??= stringField(combined, "model");
        tail = `${tail}${text}`.slice(-MAX_TAIL_CHARS);
      },
      flush() {
        tail = `${tail}${decoder.decode()}`.slice(-MAX_TAIL_CHARS);
        onComplete(usageFromTail(tail, model));
      },
    }),
  );
}

function usageFromTail(tail: string, model?: string): ModelUsage | null {
  const marker = tail.lastIndexOf('"usage"');
  if (marker < 0) return null;
  const start = tail.indexOf("{", marker);
  if (start < 0) return null;
  const raw = balancedObject(tail, start);
  if (!raw) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) return null;
    const inputTokens = finiteInteger(value.input_tokens);
    const outputTokens = finiteInteger(value.output_tokens);
    if (inputTokens === null || outputTokens === null) return null;
    const details = isRecord(value.input_tokens_details)
      ? value.input_tokens_details
      : null;
    const cachedInputTokens = finiteInteger(details?.cached_tokens) ?? 0;
    return {
      ...(model ? { model } : {}),
      inputTokens,
      cachedInputTokens,
      outputTokens,
      totalTokens:
        finiteInteger(value.total_tokens) ?? inputTokens + outputTokens,
    };
  } catch {
    return null;
  }
}

function balancedObject(value: string, start: number): string | null {
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let index = start; index < value.length; index++) {
    const character = value[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
      continue;
    }
    if (character === '"') quoted = true;
    else if (character === "{") depth++;
    else if (character === "}" && --depth === 0)
      return value.slice(start, index + 1);
  }
  return null;
}

function stringField(value: string, field: string): string | undefined {
  const match = new RegExp(`"${field}"\\s*:\\s*"([^"\\\\]{1,200})"`).exec(
    value,
  );
  return match?.[1];
}

function finiteInteger(value: unknown): number | null {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    Number.isInteger(value) &&
    value >= 0
    ? value
    : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export const __test = { usageFromTail };
