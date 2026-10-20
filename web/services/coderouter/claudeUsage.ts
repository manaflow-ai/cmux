// Token accounting for the Anthropic Messages API, streaming or not.
//
// Streaming responses carry input counts in `message_start` (near the head)
// and the final cumulative `output_tokens` in the last `message_delta` (at
// the tail). Non-streaming responses carry one `usage` object near the end.
// Both are covered by retaining a bounded head and a bounded tail; nothing in
// between is kept, and no prompt or model output is logged or persisted.

export type ClaudeUsage = {
  readonly model?: string;
  readonly inputTokens: number;
  readonly cacheReadInputTokens: number;
  readonly cacheCreationInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
};

const MAX_HEAD_CHARS = 64 * 1024;
const MAX_TAIL_CHARS = 64 * 1024;

export function observeClaudeUsage(
  body: ReadableStream<Uint8Array> | null,
  onComplete: (usage: ClaudeUsage | null) => void,
): ReadableStream<Uint8Array> | null {
  if (!body) {
    onComplete(null);
    return null;
  }
  const decoder = new TextDecoder();
  let head = "";
  let tail = "";
  let seen = 0;
  return body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        controller.enqueue(chunk);
        const text = decoder.decode(chunk, { stream: true });
        if (head.length < MAX_HEAD_CHARS) {
          head = `${head}${text}`.slice(0, MAX_HEAD_CHARS);
        }
        tail = `${tail}${text}`.slice(-MAX_TAIL_CHARS);
        seen += text.length;
      },
      flush() {
        const rest = decoder.decode();
        tail = `${tail}${rest}`.slice(-MAX_TAIL_CHARS);
        seen += rest.length;
        onComplete(usageFromText(seen > MAX_HEAD_CHARS ? `${head}\n${tail}` : `${head}${rest}`));
      },
    }),
  );
}

export function usageFromText(text: string): ClaudeUsage | null {
  const model = stringField(text, "model");
  let input: UsageObject | null = null;
  let output: number | null = null;
  for (const candidate of usageObjects(text)) {
    if (input === null && candidate.inputTokens !== null) input = candidate;
    if (candidate.outputTokens !== null) output = candidate.outputTokens;
  }
  if (!input || output === null) return null;
  const inputTokens = input.inputTokens ?? 0;
  const cacheRead = input.cacheReadInputTokens ?? 0;
  const cacheCreation = input.cacheCreationInputTokens ?? 0;
  return {
    ...(model ? { model } : {}),
    inputTokens,
    cacheReadInputTokens: cacheRead,
    cacheCreationInputTokens: cacheCreation,
    outputTokens: output,
    totalTokens: inputTokens + cacheRead + cacheCreation + output,
  };
}

type UsageObject = {
  readonly inputTokens: number | null;
  readonly cacheReadInputTokens: number | null;
  readonly cacheCreationInputTokens: number | null;
  readonly outputTokens: number | null;
};

function* usageObjects(text: string): Generator<UsageObject> {
  let from = 0;
  for (;;) {
    const marker = text.indexOf('"usage"', from);
    if (marker < 0) return;
    from = marker + 7;
    const start = text.indexOf("{", marker);
    if (start < 0) return;
    const raw = balancedObject(text, start);
    if (!raw) continue;
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      continue;
    }
    if (!isRecord(value)) continue;
    yield {
      inputTokens: finiteInteger(value.input_tokens),
      cacheReadInputTokens: finiteInteger(value.cache_read_input_tokens),
      cacheCreationInputTokens: finiteInteger(value.cache_creation_input_tokens),
      outputTokens: finiteInteger(value.output_tokens),
    };
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
    else if (character === "}" && --depth === 0) {
      return value.slice(start, index + 1);
    }
  }
  return null;
}

function stringField(value: string, field: string): string | undefined {
  const match = new RegExp(`"${field}"\\s*:\\s*"([^"\\\\]{1,200})"`).exec(value);
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
