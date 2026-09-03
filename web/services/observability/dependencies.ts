import { SpanKind, type Attributes } from "@opentelemetry/api";
import type { Span, SpanProcessor } from "@opentelemetry/sdk-trace-base";

/**
 * Stable names for the third parties the web app calls, keyed by host. The
 * name is what dashboards group by; a host that is not listed keeps its
 * hostname as the name so a new dependency is visible the day it appears.
 */
const DEPENDENCY_NAMES: ReadonlyArray<readonly [RegExp, string]> = [
  [/(^|\.)freestyle\.sh$/, "freestyle"],
  [/(^|\.)stack-auth\.com$/, "stack-auth"],
  [/(^|\.)stripe\.com$/, "stripe"],
  [/(^|\.)posthog\.com$/, "posthog"],
  [/^r\.cmux\.com$/, "posthog"],
  [/(^|\.)sentry\.io$/, "sentry"],
  [/(^|\.)slack\.com$/, "slack"],
  [/(^|\.)github\.com$/, "github"],
  [/(^|\.)googleapis\.com$/, "google"],
  [/(^|\.)apple\.com$/, "apple"],
  [/(^|\.)axiom\.co$/, "axiom"],
  [/(^|\.)vercel\.com$/, "vercel"],
  [/(^|\.)blob\.vercel-storage\.com$/, "vercel-blob"],
  [/(^|\.)resend\.com$/, "resend"],
  [/(^|\.)openai\.com$/, "openai"],
  [/(^|\.)anthropic\.com$/, "anthropic"],
  [/(^|\.)amazonaws\.com$/, "aws"],
  [/(^|\.)cloudflare\.com$/, "cloudflare"],
  [/(^|\.)cmux\.com$/, "cmux"],
  [/(^|\.)cmux\.sh$/, "cmux-vm"],
];

export function dependencyNameForHost(host: string): string {
  const normalized = host.trim().toLowerCase().replace(/:\d+$/, "");
  for (const [pattern, name] of DEPENDENCY_NAMES) {
    if (pattern.test(normalized)) return name;
  }
  return normalized || "unknown";
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// vm-<hex>, sh-<alnum>, cus_<alnum>, price_<alnum>, dpl_<alnum>, prj_<alnum>, ...
const PREFIXED_ID = /^[a-z]{1,12}[-_][A-Za-z0-9_-]{6,}$/;
const HEX_ID = /^[0-9a-f]{12,}$/i;
const NUMERIC_ID = /^\d{2,}$/;
const LONG_TOKEN = /^[A-Za-z0-9_-]{20,}$/;

/**
 * Replace the id-shaped segments of a URL path with `{id}` so one endpoint
 * is one route: `/v5/vms/vm-c29e0db6/exec-await` -> `/v5/vms/{id}/exec-await`,
 * `/api/v1/users/98c67a48-...` -> `/api/v1/users/{id}`. Segments that read as
 * words (`vms`, `exec-await`, `oauth`) are kept.
 */
export function templateDependencyPath(path: string): string {
  const [pathname] = path.split("?", 1);
  const segments = pathname.split("/");
  const templated = segments.map((segment) => {
    if (segment.length === 0) return segment;
    if (UUID.test(segment) || HEX_ID.test(segment) || NUMERIC_ID.test(segment)) return "{id}";
    if (LONG_TOKEN.test(segment) && /\d/.test(segment)) return "{id}";
    if (PREFIXED_ID.test(segment) && /\d/.test(segment)) return "{id}";
    return segment;
  });
  return templated.join("/") || "/";
}

export type DependencyAttributes = {
  readonly "cmux.dep.name": string;
  readonly "cmux.dep.host"?: string;
  readonly "cmux.dep.method"?: string;
  readonly "cmux.dep.path"?: string;
  /** `POST /v5/vms/{id}/exec-await`: the grouping key for failure rate and latency. */
  readonly "cmux.dep.route": string;
};

function firstString(attributes: Attributes, keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = attributes[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

/**
 * Derive the dependency attributes for one outbound span from what its
 * instrumentation set at start: an HTTP client span carries the URL and
 * method (`@vercel/otel/fetch`: `http.url`, `http.method`; semconv:
 * `url.full`, `http.request.method`), a database span carries `db.system`.
 * Returns undefined for spans that are not calls to another system.
 */
export function dependencyAttributes(
  kind: SpanKind,
  attributes: Attributes,
): DependencyAttributes | undefined {
  if (kind !== SpanKind.CLIENT && kind !== SpanKind.PRODUCER) return undefined;
  const url = firstString(attributes, ["http.url", "url.full"]);
  if (url) {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return undefined;
    }
    const method = (firstString(attributes, ["http.request.method", "http.method"]) ?? "GET").toUpperCase();
    const path = templateDependencyPath(parsed.pathname);
    return {
      "cmux.dep.name": dependencyNameForHost(parsed.host),
      "cmux.dep.host": parsed.host.toLowerCase(),
      "cmux.dep.method": method,
      "cmux.dep.path": path,
      "cmux.dep.route": `${method} ${path}`,
    };
  }
  const dbSystem = firstString(attributes, ["db.system", "db.system.name"]);
  if (dbSystem) {
    const operation = firstString(attributes, ["db.operation.name", "db.operation"]) ?? "query";
    const target = firstString(attributes, ["db.collection.name", "db.sql.table", "db.name"]);
    return {
      "cmux.dep.name": dbSystem.toLowerCase(),
      "cmux.dep.route": target ? `${operation} ${target}` : operation,
    };
  }
  return undefined;
}

/**
 * Stamps `cmux.dep.*` on every outbound span as it starts, so Axiom can
 * report failure rate and latency per third party and per endpoint
 * (`summarize ... by ['cmux.dep.name'], ['cmux.dep.route']`) without regex
 * over raw URLs full of machine and user ids. Read-only after start: the
 * response status stays where the instrumentation puts it
 * (`http.status_code` / `http.response.status_code`).
 */
export class DependencySpanProcessor implements SpanProcessor {
  onStart(span: Span): void {
    try {
      const attributes = dependencyAttributes(span.kind, span.attributes);
      if (attributes) span.setAttributes(attributes);
    } catch {
      // Telemetry decoration must never break a request.
    }
  }

  onEnd(): void {}

  forceFlush(): Promise<void> {
    return Promise.resolve();
  }

  shutdown(): Promise<void> {
    return Promise.resolve();
  }
}
