import type { Event } from "@sentry/nextjs";

const SECRET_KEY_MARKER =
  /(?:^|_)(?:auth|authorization|body|completion|content|cookie|credentials?|email|handoff|lease|output|password|passwd|prompt|provider_account|pwd|response|secret|session|token)(?:_|$)/;
const SECRET_KEY_SHAPE =
  /(?:^|_)(?:(?:api|access|private|client)_?key|ciphertext|encrypted_data_key)(?:_|$)/;
const SAFE_TELEMETRY_KEY =
  /^(?:(?:completion|output|prompt)_tokens|(?:http_)?response_status(?:_code)?|content_type|auth_method)$/;
const SECRET_QUERY_KEY =
  /^(?:access_token|refresh_token|token|key|api_key|apikey|sig|signature|code|auth|authorization|password|passwd|pwd|secret)$/i;
const SECRET_QUERY_COMPONENT =
  /(?:^|_)(?:auth|authorization|code|credentials?|key|password|passwd|pwd|secret|sig|signature|token)(?:_|$)/;
const QUERY_ASSIGNMENT = /(?=(^|[?&#;\s="'=(:,])([^=?&#;\s"']+)=)/g;
const ROUTE_TOKEN = /\b(?:crt|crk)_[A-Za-z0-9_-]{32,}\b/g;
const HANDOFF_LEASE = /\bcrh_[A-Za-z0-9_-]{32,}\b/g;
const BEARER_TOKEN = /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b/gi;
const JWT = /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b/g;
const PROVIDER_SECRET =
  /\b(?:(?:sk|srt|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs])[-_][A-Za-z0-9_-]{8,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b/g;
const URL_CREDENTIALS = /([A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^/?#\s]+@/g;
const EMAIL = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/g;
const CREDENTIAL_HEADER =
  /\b((?:proxy-)?authorization|(?:set-)?cookie)(\s*[:=]\s*)[^\r\n]+/gi;
const SECRET_ASSIGNMENT =
  /\b([A-Za-z_][A-Za-z0-9_-]*)((?:(?:\\+)?["'])?\s*[:=]\s*)/g;

/**
 * Defense in depth for telemetry. Product code must still avoid attaching
 * request bodies, auth headers, credentials, email addresses, or account
 * labels to Sentry events.
 */
export function scrubSentryEvent<T extends Event>(event: T): T {
  scrubValue(event);
  if (event.request) {
    const request = event.request as unknown as Record<string, unknown>;
    if ("query_string" in request) {
      request.query_string = scrubQueryString(request.query_string);
    }
    delete event.request.data;
    delete event.request.cookies;
    delete event.request.headers;
  }
  delete event.user;
  return event;
}

/**
 * beforeSend gate for the shared cmux Sentry project. The Next.js app serves
 * far more than coderouter, and Sentry bills per event, so raw unhandled
 * request errors (`onRequestError`) stay out unless they are coderouter's.
 * Every error a cmux helper reports on purpose (`reportError`, the
 * `capture*Error` helpers in services/errors.ts) carries an explicit
 * `subsystem` tag or the `cmux` context, and passes. Until 2026-10-07 this
 * gate allowlisted a few subsystems and silently dropped the rest, including
 * App Store Connect, cron, teams and auth reports.
 */
export function shouldSendSentryEvent(event: Event): boolean {
  if (isDeliberateReport(event)) return true;
  const message =
    event.message ??
    event.exception?.values?.map((value) => value.value ?? "").join(" ") ??
    "";
  if (message.startsWith("coderouter.")) return true;
  const url = event.request?.url;
  if (!url) return false;
  try {
    return new URL(url).hostname.toLowerCase() === "coderouter.dev";
  } catch {
    return false;
  }
}

function isDeliberateReport(event: Event): boolean {
  const subsystem = event.tags?.subsystem;
  if (typeof subsystem === "string" && subsystem.trim() !== "") return true;
  // reportError (services/observability/report.ts) always sets this context
  // inside its own scope; nothing else in the app writes it.
  const cmux = event.contexts?.cmux;
  return typeof cmux === "object" && cmux !== null;
}

function scrubValue(value: unknown): void {
  if (!value || typeof value !== "object") return;
  for (const [childKey, child] of Object.entries(value)) {
    if (isSensitiveKey(childKey)) {
      (value as Record<string, unknown>)[childKey] = "[Filtered]";
      continue;
    }
    if (typeof child === "string") {
      (value as Record<string, unknown>)[childKey] = scrubString(child);
    } else {
      scrubValue(child);
    }
  }
}

function isSensitiveKey(key: string): boolean {
  const normalized = normalizedKey(key);
  if (SAFE_TELEMETRY_KEY.test(normalized)) return false;
  return SECRET_KEY_MARKER.test(normalized) || SECRET_KEY_SHAPE.test(normalized);
}

function normalizedKey(key: string): string {
  return key
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
}

function scrubString(value: string): string {
  const scrubbed = value
    .replace(URL_CREDENTIALS, "$1[Filtered credentials]@")
    .replace(CREDENTIAL_HEADER, "$1$2[Filtered]")
    .replace(ROUTE_TOKEN, "[Filtered route token]")
    .replace(HANDOFF_LEASE, "[Filtered handoff lease]")
    .replace(BEARER_TOKEN, "Bearer [Filtered]")
    .replace(JWT, "[Filtered JWT]")
    .replace(PROVIDER_SECRET, "[Filtered provider secret]");
  return scrubQueryAssignments(scrubSecretAssignments(scrubbed)).replace(
    EMAIL,
    "[Filtered email]",
  );
}

function scrubSecretAssignments(value: string): string {
  let output = "";
  let cursor = 0;
  let changed = false;
  SECRET_ASSIGNMENT.lastIndex = 0;
  for (let match = SECRET_ASSIGNMENT.exec(value); match; match = SECRET_ASSIGNMENT.exec(value)) {
    if (!isSensitiveKey(match[1])) continue;
    const valueStart = match.index + match[0].length;
    const valueEnd = secretValueEnd(value, valueStart);
    output += `${value.slice(cursor, valueStart)}[Filtered]`;
    cursor = valueEnd;
    changed = true;
    SECRET_ASSIGNMENT.lastIndex = valueEnd;
  }
  return changed ? output + value.slice(cursor) : value;
}

function secretValueEnd(value: string, start: number): number {
  let quoteIndex = start;
  while (value[quoteIndex] === "\\") quoteIndex += 1;
  const quote = value[quoteIndex];
  if (quote !== '"' && quote !== "'") {
    let end = start;
    while (end < value.length && !/[\r\n&,;}]/.test(value[end])) {
      if (/\s/.test(value[end]) && hasAssignmentAfterWhitespace(value, end)) return end;
      end += 1;
    }
    return end;
  }

  const delimiterEscapeDepth = quoteIndex - start;
  let index = quoteIndex + 1;
  while (index < value.length) {
    if (value[index] === "\n" || value[index] === "\r") return index;
    if (value[index] === "\\") {
      const runStart = index;
      while (value[index] === "\\") index += 1;
      if (value[index] === quote) {
        if (index - runStart === delimiterEscapeDepth) return index + 1;
        index += 1;
      }
      continue;
    }
    if (delimiterEscapeDepth === 0 && value[index] === quote) return index + 1;
    index += 1;
  }
  return value.length;
}

function hasAssignmentAfterWhitespace(value: string, start: number): boolean {
  let index = start;
  while (index < value.length && /[\t\v\f ]/.test(value[index])) index += 1;
  return /^[A-Za-z_][A-Za-z0-9_\[\].-]*\s*[:=]/.test(value.slice(index));
}

function scrubQueryAssignments(value: string): string {
  const ranges: Array<{ start: number; end: number }> = [];
  let coveredUntil = 0;
  QUERY_ASSIGNMENT.lastIndex = 0;
  for (let match = QUERY_ASSIGNMENT.exec(value); match; match = QUERY_ASSIGNMENT.exec(value)) {
    const prefix = match[1];
    const key = match[2];
    const valueStart = match.index + prefix.length + key.length + 1;
    if (valueStart >= coveredUntil && isSensitiveQueryKey(key)) {
      const valueEnd = queryValueEnd(value, valueStart);
      ranges.push({ start: valueStart, end: valueEnd });
      coveredUntil = valueEnd;
    }
    QUERY_ASSIGNMENT.lastIndex = match.index + 1;
  }
  let result = value;
  for (const range of ranges.reverse()) {
    result = `${result.slice(0, range.start)}[Filtered]${result.slice(range.end)}`;
  }
  return result;
}

function queryValueEnd(value: string, start: number): number {
  let end = start;
  while (end < value.length && !/[\r\n&#;}]/.test(value[end])) {
    if (/\s/.test(value[end]) && hasAssignmentAfterWhitespace(value, end)) return end;
    end += 1;
  }
  return end;
}

function scrubQueryString(value: unknown): unknown {
  if (typeof value === "string") {
    return scrubString(value);
  }
  if (Array.isArray(value)) {
    return value.map((entry) => {
      if (Array.isArray(entry) && typeof entry[0] === "string" && entry.length >= 2) {
        return isSensitiveQueryKey(entry[0])
          ? [entry[0], "[Filtered]", ...entry.slice(2)]
          : entry;
      }
      return scrubQueryString(entry);
    });
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [
        key,
        isSensitiveQueryKey(key) ? "[Filtered]" : scrubQueryString(child),
      ]),
    );
  }
  return value;
}

function isSensitiveQueryKey(key: string): boolean {
  let decoded = key;
  try {
    decoded = decodeURIComponent(key.replace(/\+/g, " "));
  } catch {
    // Keep the undecoded key. It may still contain a recognizable credential
    // component, and malformed telemetry must not bypass the scrubber.
  }
  return (
    SECRET_QUERY_KEY.test(decoded) ||
    SECRET_QUERY_COMPONENT.test(normalizedKey(decoded))
  );
}
