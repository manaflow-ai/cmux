// PostHog Error Tracking (`$exception`) event bodies for coderouter.
//
// PostHog groups `$exception` events into issues by `$exception_fingerprint`.
// It is a third-party analytics sink, so it receives only a structured error
// class and source frames from known repository paths. The original error and
// stack stay in Sentry, where the server-side scrubbing policy applies.
import type { CoderouterRawEvent } from "./analytics";

const SENSITIVE_TEXT = [
  /(?:https?|postgres(?:ql)?:)\/\/[^\s/@]+:[^\s/@]+@[^\s]+/gi,
  /https?:\/\/[^\s]*(?:hooks\.slack\.com|api\.sentry\.io|posthog)[^\s]*/gi,
  /\b(?:Bearer|Basic)\s+[^\s]+/gi,
  /\b(?:srt|sk|crt|xox[baprs]|gh[pousr])[_-][A-Za-z0-9_-]{8,}\b/gi,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b/g,
  /\b[A-Z0-9]{20,}\b/g,
  /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g,
  /\b(?:password|passphrase|secret|token|api[_-]?key|authorization|cookie|dsn|private[_-]?key)\s*[:=]\s*[^\s,;]+/gi,
];
const VALUE_MAX = 200;

const SAFE_ERROR_NAMES = new Set([
  "AggregateError",
  "AbortError",
  "Error",
  "EvalError",
  "FetchError",
  "PostgresError",
  "RangeError",
  "ReferenceError",
  "SyntaxError",
  "TimeoutError",
  "TypeError",
  "URIError",
  "ZodError",
]);

export function scrubTelemetryText(text: string): string {
  return SENSITIVE_TEXT.reduce((value, pattern) => value.replace(pattern, "[redacted]"), text);
}

export function errorSummary(error: unknown): string {
  if (error instanceof Error) return `${safeErrorName(error.name)}: message redacted`;
  return "Unknown error: message redacted";
}

export type StackFrame = {
  readonly filename: string;
  readonly function: string;
  readonly lineno?: number;
  readonly colno?: number;
  readonly in_app: boolean;
  readonly platform: "node:javascript";
};

const FRAME_WITH_LOCATION = /^\s*at\s+(?:(.+?)\s+\()?(.+?):(\d+):(\d+)\)?\s*$/;
const MAX_FRAMES = 40;

/**
 * V8 stack lines to PostHog raw frames, outermost first (Sentry order). Best
 * effort: an unparseable line is skipped, never a reason to drop the event.
 */
export function stackFrames(error: unknown): StackFrame[] {
  const stack = error instanceof Error ? error.stack : undefined;
  if (!stack) return [];
  const frames: StackFrame[] = [];
  for (const line of stack.split("\n")) {
    const match = FRAME_WITH_LOCATION.exec(line);
    if (!match) continue;
    const [, fn, file, lineno, colno] = match;
    const filename = safeFrameFilename(file ?? "");
    if (!filename) continue;
    frames.push({
      filename,
      function: safeFunctionName(fn),
      lineno: Number(lineno),
      colno: Number(colno),
      in_app: !filename.includes("node_modules") && !filename.startsWith("node:"),
      platform: "node:javascript",
    });
    if (frames.length >= MAX_FRAMES) break;
  }
  return frames.reverse();
}

export type CoderouterExceptionInput = {
  readonly type: string;
  readonly value: string;
  readonly fingerprint: string;
  readonly level: "error" | "warning";
  readonly error?: unknown;
  readonly handled?: boolean;
  readonly userId?: string;
  readonly teamId?: string;
  readonly properties?: Readonly<Record<string, string | number | boolean | null | undefined>>;
};

export function exceptionEvent(input: CoderouterExceptionInput): CoderouterRawEvent {
  const frames = stackFrames(input.error);
  const errorName = safeErrorName(input.type);
  const value = input.error === undefined
    ? scrubTelemetryText(input.value).slice(0, 500)
    : `${errorName}: message redacted`;
  return {
    event: "$exception",
    userId: input.userId,
    teamId: input.teamId,
    properties: {
      ...cleanTelemetryProperties(input.properties ?? {}),
      $exception_level: input.level,
      $exception_fingerprint: input.fingerprint.slice(0, VALUE_MAX),
      $exception_list: JSON.stringify([
        {
          type: errorName,
          value,
          mechanism: {
            handled: input.handled ?? true,
            type: "coderouter",
            synthetic: input.error === undefined,
          },
          ...(frames.length > 0 ? { stacktrace: { type: "raw", frames } } : {}),
        },
      ]),
    },
  };
}

function safeErrorName(value: string): string {
  const name = value.trim();
  if (SAFE_ERROR_NAMES.has(name)) return name;
  if (/^coderouter[._][a-z0-9_.-]{1,80}$/i.test(name)) return name;
  return "Error";
}

function safeFrameFilename(value: string): string | undefined {
  // Keep only a relative path below a checked-in source root. This drops
  // temporary paths, URLs, query strings, and user-controlled filenames.
  const normalized = value.replace(/^file:\/\//, "");
  const match = normalized.match(/(?:^|\/)((?:web\/(?:app|services|db|scripts)|CLI|Sources)\/[A-Za-z0-9._/-]+)$/);
  if (!match || match[1]!.includes("..")) return undefined;
  return match[1]!.slice(0, VALUE_MAX);
}

function safeFunctionName(value: string | undefined): string {
  const name = value?.trim() ?? "";
  return /^[A-Za-z_$][A-Za-z0-9_$]*(?:[.$][A-Za-z_$][A-Za-z0-9_$]*){0,5}$/.test(name)
    ? name.slice(0, 120)
    : "<anonymous>";
}

export function cleanTelemetryProperties(
  input: Readonly<Record<string, string | number | boolean | null | undefined>>,
): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(input)) {
    if (value === null || value === undefined) continue;
    out[key] = typeof value === "string" ? scrubTelemetryText(value).slice(0, VALUE_MAX) : value;
  }
  return out;
}
