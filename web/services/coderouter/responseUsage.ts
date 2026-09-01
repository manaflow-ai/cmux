export type ModelUsage = {
  readonly model?: string;
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  /** Anthropic prompt-cache writes (billed above plain input); 0 elsewhere. */
  readonly cacheCreationInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
};

const MAX_HEAD_CHARS = 64 * 1024;
const MAX_TAIL_CHARS = 256 * 1024;

/**
 * Passes upstream bytes through immediately while retaining only a bounded
 * head, a bounded rolling tail, and a model identifier. No prompt or model
 * output is logged, persisted, or sent to analytics.
 *
 * OpenAI-shaped streams carry one complete usage object at the end. Anthropic
 * Messages streams split it: `message_start` (in the head) carries the input
 * and cache counts, `message_delta` (in the tail) carries the output count, so
 * the two are merged when the tail alone is incomplete.
 */
export function observeModelUsage(
  body: ReadableStream<Uint8Array> | null,
  onComplete: (usage: ModelUsage | null) => void,
  onError?: (error: unknown) => void,
): ReadableStream<Uint8Array> | null {
  if (!body) {
    onComplete(null);
    return null;
  }
  const decoder = new TextDecoder();
  let head = "";
  let tail = "";
  let model: string | undefined;
  const source = onError ? reportStreamErrors(body, onError) : body;
  return source.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        controller.enqueue(chunk);
        const text = decoder.decode(chunk, { stream: true });
        const combined = `${tail.slice(-256)}${text}`;
        model ??= stringField(combined, "model");
        if (head.length < MAX_HEAD_CHARS) {
          head = `${head}${text}`.slice(0, MAX_HEAD_CHARS);
        }
        tail = `${tail}${text}`.slice(-MAX_TAIL_CHARS);
      },
      flush() {
        tail = `${tail}${decoder.decode()}`.slice(-MAX_TAIL_CHARS);
        onComplete(usageFromStream(head, tail, model));
      },
    }),
  );
}

/**
 * A provider stream that fails mid-response errors the client's stream (the
 * route handler has long since returned), so the failure would otherwise be
 * invisible to observability. Surface it once, then propagate unchanged.
 */
export function reportStreamErrors(
  body: ReadableStream<Uint8Array>,
  onError: (error: unknown) => void,
): ReadableStream<Uint8Array> {
  const reader = body.getReader();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const { value, done } = await reader.read();
        if (done) controller.close();
        else controller.enqueue(value);
      } catch (error) {
        // A client hang-up cancels the response body, which surfaces here as
        // an abort-class rejection; that is not a provider failure.
        if (!isAbortError(error)) onError(error);
        controller.error(error);
      }
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}

function isAbortError(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const name = (error as { name?: unknown }).name;
  return name === "AbortError" || name === "TimeoutError";
}

type UsageCounts = {
  readonly inputTokens: number | null;
  readonly cachedInputTokens: number | null;
  readonly cacheCreationInputTokens: number | null;
  readonly outputTokens: number | null;
  readonly totalTokens: number | null;
};

function usageFromStream(head: string, tail: string, model?: string): ModelUsage | null {
  const last = usageCounts(tail, tail.lastIndexOf('"usage"'));
  if (!last) return null;
  let counts = last;
  if (counts.inputTokens === null || counts.outputTokens === null) {
    // Anthropic streaming: input-side counts live in the first usage object.
    const first = usageCounts(head, head.indexOf('"usage"'));
    if (first) {
      counts = {
        inputTokens: counts.inputTokens ?? first.inputTokens,
        cachedInputTokens: counts.cachedInputTokens ?? first.cachedInputTokens,
        cacheCreationInputTokens:
          counts.cacheCreationInputTokens ?? first.cacheCreationInputTokens,
        outputTokens: counts.outputTokens ?? first.outputTokens,
        totalTokens: counts.totalTokens,
      };
    }
  }
  const inputTokens = counts.inputTokens;
  const outputTokens = counts.outputTokens;
  if (inputTokens === null || outputTokens === null) return null;
  return {
    ...(model ? { model } : {}),
    inputTokens,
    cachedInputTokens: counts.cachedInputTokens ?? 0,
    cacheCreationInputTokens: counts.cacheCreationInputTokens ?? 0,
    outputTokens,
    totalTokens: counts.totalTokens ?? inputTokens + outputTokens,
  };
}

function usageCounts(text: string, marker: number): UsageCounts | null {
  if (marker < 0) return null;
  const start = text.indexOf("{", marker);
  if (start < 0) return null;
  const raw = balancedObject(text, start);
  if (!raw) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value)) return null;
    const details = isRecord(value.input_tokens_details)
      ? value.input_tokens_details
      : null;
    return {
      inputTokens: finiteInteger(value.input_tokens),
      // OpenAI shape nests cached reads under input_tokens_details; the
      // Anthropic Messages shape reports them as cache_read_input_tokens.
      cachedInputTokens: finiteInteger(details?.cached_tokens) ??
        finiteInteger(value.cache_read_input_tokens),
      cacheCreationInputTokens: finiteInteger(value.cache_creation_input_tokens),
      outputTokens: finiteInteger(value.output_tokens),
      totalTokens: finiteInteger(value.total_tokens),
    };
  } catch {
    return null;
  }
}

function usageFromTail(tail: string, model?: string): ModelUsage | null {
  return usageFromStream("", tail, model);
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

export const __test = { usageFromTail, usageFromStream };
