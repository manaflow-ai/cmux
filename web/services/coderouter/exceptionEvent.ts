// PostHog Error Tracking (`$exception`) event bodies for coderouter.
//
// PostHog groups `$exception` events into issues by `$exception_fingerprint`
// and renders `$exception_list[].stacktrace` when frames are supplied in the
// Sentry-compatible raw shape. Messages and filenames are scrubbed of token
// grammars before they leave the process; no request body, header, credential
// or email is accepted here.
import type { CoderouterRawEvent } from "./analytics";

const SENSITIVE_TEXT = /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,}|crt_[A-Za-z0-9_-]{16,})/g;
const VALUE_MAX = 200;

export function scrubTelemetryText(text: string): string {
  return text.replace(SENSITIVE_TEXT, "[redacted]");
}

export function errorSummary(error: unknown): string {
  if (error instanceof Error) return scrubTelemetryText(`${error.name}: ${error.message}`);
  return scrubTelemetryText(String(error));
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
    const filename = scrubTelemetryText(file ?? "").slice(0, VALUE_MAX);
    frames.push({
      filename,
      function: (fn ?? "<anonymous>").slice(0, 120),
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
          type: input.type.slice(0, 120),
          value: scrubTelemetryText(input.value).slice(0, 500),
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
