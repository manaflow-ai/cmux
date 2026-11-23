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

/**
 * `observeClaudeUsage` for a body whose cost must be charged even when it
 * never reaches its final usage: the house Claude route (claudeFallback.ts),
 * where an unrecorded completion is model usage given away past the cap.
 *
 * A stream the client cancels, or that breaks, never reaches the flush that
 * reads the final usage, so the plain observer records nothing for it. Here
 * that case reports an estimate of what was delivered instead: the input
 * counts from `message_start`, and output as the larger of the last reported
 * `output_tokens` and one token per three characters of delta text. A
 * non-streaming body cut short (its usage sits at the end) is charged its
 * delivered characters as output plus the request's bytes as input. Nothing
 * delivered, nothing charged. `onUsage` runs exactly once.
 */
export function observeClaudeUsageCharged(
  body: ReadableStream<Uint8Array> | null,
  request: { readonly bytes: number; readonly model: string | null },
  onUsage: (usage: ClaudeUsage | null) => void,
): ReadableStream<Uint8Array> | null {
  let parsed: ClaudeUsage | null = null;
  const observed = observeClaudeUsage(body, (usage) => {
    parsed = usage;
  });
  if (!observed) {
    onUsage(null);
    return null;
  }
  const delivered = new DeliveredClaudeUsage(request.bytes, request.model);
  let reported = false;
  const report = (usage: ClaudeUsage | null) => {
    if (reported) return;
    reported = true;
    onUsage(usage);
  };
  const reader = observed.getReader();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      let next: ReadableStreamReadResult<Uint8Array>;
      try {
        next = await reader.read();
      } catch (error) {
        report(delivered.usage());
        controller.error(error);
        return;
      }
      if (next.done) {
        report(parsed ?? delivered.usage());
        controller.close();
        return;
      }
      delivered.push(next.value);
      controller.enqueue(next.value);
    },
    async cancel(reason) {
      report(delivered.usage());
      await reader.cancel(reason).catch(() => undefined);
    },
  });
}

const MAX_PENDING_EVENT_CHARS = 1024 * 1024;
const CHARS_PER_OUTPUT_TOKEN = 3;
const BYTES_PER_INPUT_TOKEN = 4;

/** What a partly delivered Messages response has cost so far; see observeClaudeUsageCharged. */
export class DeliveredClaudeUsage {
  private readonly decoder = new TextDecoder();
  private pending = "";
  private seenChars = 0;
  private streamed: boolean | null = null;
  private model: string | undefined;
  private input: UsageObject | null = null;
  private reportedOutput = 0;
  private deltaChars = 0;

  constructor(
    private readonly requestBytes: number,
    requestModel: string | null,
  ) {
    this.model = requestModel ?? undefined;
  }

  push(chunk: Uint8Array): void {
    const text = this.decoder.decode(chunk, { stream: true });
    this.seenChars += text.length;
    if (this.streamed === null && text.trimStart().length > 0) {
      this.streamed = !text.trimStart().startsWith("{");
    }
    if (!this.streamed) return;
    this.pending += text;
    for (;;) {
      const end = /\r?\n\r?\n/.exec(this.pending);
      if (!end) break;
      this.event(this.pending.slice(0, end.index));
      this.pending = this.pending.slice(end.index + end[0].length);
    }
    if (this.pending.length > MAX_PENDING_EVENT_CHARS) {
      // One event this large is delta text in all but name: charge it as such.
      this.deltaChars += this.pending.length;
      this.pending = "";
    }
  }

  /** The estimate, or null when nothing was delivered. */
  usage(): ClaudeUsage | null {
    if (this.seenChars === 0) return null;
    if (this.streamed && this.input) {
      const outputTokens = Math.max(
        this.reportedOutput,
        Math.ceil((this.deltaChars + this.pending.length) / CHARS_PER_OUTPUT_TOKEN),
      );
      const inputTokens = this.input.inputTokens ?? 0;
      const cacheRead = this.input.cacheReadInputTokens ?? 0;
      const cacheCreation = this.input.cacheCreationInputTokens ?? 0;
      return {
        ...(this.model ? { model: this.model } : {}),
        inputTokens,
        cacheReadInputTokens: cacheRead,
        cacheCreationInputTokens: cacheCreation,
        outputTokens,
        totalTokens: inputTokens + cacheRead + cacheCreation + outputTokens,
      };
    }
    // No `message_start` read (a JSON body, or a stream whose head was not a
    // Messages event): every delivered character is output, and the request's
    // bytes are its input.
    const inputTokens = Math.ceil(this.requestBytes / BYTES_PER_INPUT_TOKEN);
    const outputTokens = Math.ceil(this.seenChars / CHARS_PER_OUTPUT_TOKEN);
    return {
      ...(this.model ? { model: this.model } : {}),
      inputTokens,
      cacheReadInputTokens: 0,
      cacheCreationInputTokens: 0,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
    };
  }

  private event(raw: string): void {
    const data = raw
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trimStart())
      .join("\n");
    if (!data) return;
    let value: unknown;
    try {
      value = JSON.parse(data);
    } catch {
      this.deltaChars += data.length;
      return;
    }
    if (!isRecord(value)) return;
    if (value.type === "message_start" && isRecord(value.message)) {
      if (typeof value.message.model === "string") this.model = value.message.model;
      this.noteUsage(value.message.usage);
      return;
    }
    if (value.type === "message_delta") {
      this.noteUsage(value.usage);
      return;
    }
    if (value.type === "content_block_delta" && isRecord(value.delta)) {
      for (const field of ["text", "partial_json", "thinking"] as const) {
        const part = value.delta[field];
        if (typeof part === "string") this.deltaChars += part.length;
      }
    }
  }

  private noteUsage(raw: unknown): void {
    if (!isRecord(raw)) return;
    const usage: UsageObject = {
      inputTokens: finiteInteger(raw.input_tokens),
      cacheReadInputTokens: finiteInteger(raw.cache_read_input_tokens),
      cacheCreationInputTokens: finiteInteger(raw.cache_creation_input_tokens),
      outputTokens: finiteInteger(raw.output_tokens),
    };
    if (usage.inputTokens !== null || this.input !== null) {
      // Counts only grow within one message: keep the larger of each.
      const larger = (a: number | null | undefined, b: number | null) =>
        a === null || a === undefined ? b : b === null ? a : Math.max(a, b);
      this.input = {
        inputTokens: larger(this.input?.inputTokens, usage.inputTokens),
        cacheReadInputTokens: larger(this.input?.cacheReadInputTokens, usage.cacheReadInputTokens),
        cacheCreationInputTokens: larger(this.input?.cacheCreationInputTokens, usage.cacheCreationInputTokens),
        outputTokens: null,
      };
    }
    if (usage.outputTokens !== null) this.reportedOutput = Math.max(this.reportedOutput, usage.outputTokens);
  }
}
