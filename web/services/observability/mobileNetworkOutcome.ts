import { SpanStatusCode } from "@opentelemetry/api";

import { withSpan } from "../telemetry";

export const MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES = 64 * 1_024;
export const MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS = 100;

const EVENT_NAME = "ios_connectivity_latency";
const TERMINAL_WINDOW_EVENT_NAME = "ios_terminal_latency_window";
const TERMINAL_ANOMALY_EVENT_NAME = "ios_terminal_latency_anomaly";
const RUNTIME_ROLE = "mobileClient";
const MAX_STRING_LENGTH = 120;
const MAX_SAFE_UNSIGNED_INTEGER = 0xffff_ffff;

const phases = new Set([
  "endpoint_start", "pairing", "transport_dial", "host_auth",
  "rpc_ready", "recovery", "relay_policy", "discovery", "terminal_trace",
]);
const outcomes = new Set(["success", "failure", "timeout", "cancelled", "abandoned"]);
const failures = new Set([
  "offline", "timedOut", "connectionRefused", "hostUnreachable",
  "permissionDenied", "dnsFailed", "secureChannelFailed", "unsupportedRoute",
  "noRoute", "credentialUnavailable", "policyUnavailable", "endpointUnavailable",
  "identityMismatch", "admissionDenied", "authorizationFailed", "accountMismatch",
  "protocolViolation", "connectionClosed", "superseded", "cancelled",
  "transportIdleTimedOut", "admissionLeaseExpired", "admissionRevalidationFailed",
  "sendQueueOverflow", "routeGated", "payloadTooLarge", "resourceLimitReached",
  "attachmentCountLimitReached", "attachmentAggregateSizeLimitReached",
  "localStateUnavailable", "unknown",
]);
const transports = new Set(["unknown", "iroh", "tailscale", "websocket", "debugLoopback"]);

const allowedPropertyKeys = new Set([
  "phase", "outcome", "duration_ms", "runtime_role", "user_usable",
  "failure", "transport", "platform", "client_channel", "app_version", "build_number",
  "bundle_identifier", "os_version", "device_model",
  "window_ms", "input_count", "output_count", "presented_count",
  "correlated_output_count", "dropped_count", "output_bytes", "max_queue_depth",
  "input_to_output_p50_ms", "input_to_output_p95_ms", "input_to_output_p99_ms",
  "input_to_visible_p50_ms", "input_to_visible_p95_ms", "input_to_visible_p99_ms",
  "render_p50_ms", "render_p95_ms", "render_p99_ms",
  "input_failed_count", "histogram_version", "input_to_output_histogram", "input_to_visible_histogram", "render_histogram",
  "duration_ms", "threshold_ms", "stage",
  "trace_id", "operation", "terminal_phase",
]);

export type MobileNetworkOutcome = {
  readonly timestamp: string;
  readonly phase: string;
  readonly outcome: "success" | "failure" | "timeout" | "cancelled" | "abandoned";
  readonly durationMs: number;
  readonly runtimeRole: "mobileClient";
  readonly userUsable: boolean;
  readonly failure?: string;
  readonly transport?: string;
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
  readonly traceId?: string;
  readonly operation?: string;
  readonly terminalPhase?: string;
};

export type MobileTerminalLatencyWindow = {
  readonly timestamp: string;
  readonly windowMs: number;
  readonly inputFailedCount?: number;
  readonly histograms?: Readonly<Record<string, string>>;
  readonly inputCount: number;
  readonly outputCount: number;
  readonly presentedCount: number;
  readonly correlatedOutputCount: number;
  readonly droppedCount: number;
  readonly outputBytes: number;
  readonly maxQueueDepth: number;
  readonly inputToOutputP50Ms: number;
  readonly inputToOutputP95Ms: number;
  readonly inputToOutputP99Ms: number;
  readonly inputToVisibleP50Ms: number;
  readonly inputToVisibleP95Ms: number;
  readonly inputToVisibleP99Ms: number;
  readonly renderP50Ms: number;
  readonly renderP95Ms: number;
  readonly renderP99Ms: number;
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export type MobileTerminalLatencyAnomaly = {
  readonly timestamp: string;
  readonly durationMs: number;
  readonly thresholdMs: number;
  readonly stage: "input_to_output" | "render";
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export type MobileObservabilityEvent = MobileNetworkOutcome | MobileTerminalLatencyWindow | MobileTerminalLatencyAnomaly;

export function parseMobileNetworkOutcome(candidate: unknown): MobileNetworkOutcome | null {
  if (!isRecord(candidate) || candidate.event !== EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const core = parseCore(candidate.properties);
  const metadata = parseMetadata(candidate.properties);
  if (!core || !metadata) return null;

  return {
    timestamp: candidate.timestamp,
    ...core,
    runtimeRole: RUNTIME_ROLE,
    ...metadata,
  };
}

export function parseMobileTerminalLatencyWindow(candidate: unknown): MobileTerminalLatencyWindow | null {
  if (!isRecord(candidate) || candidate.event !== TERMINAL_WINDOW_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const properties = candidate.properties;
  const metadata = parseMetadata(properties);
  const numbers = parseTerminalNumbers(properties);
  const histograms = parseTerminalHistograms(properties);
  if (!metadata || !numbers || histograms === null) return null;
  return {
    timestamp: candidate.timestamp,
    ...numbers,
    ...(histograms ? { histograms } : {}),
    ...metadata,
  };
}

const terminalNumericKeys = [
  "window_ms", "input_count", "output_count", "presented_count", "correlated_output_count",
  "dropped_count", "output_bytes", "max_queue_depth", "input_to_output_p50_ms",
  "input_to_output_p95_ms", "input_to_output_p99_ms", "input_to_visible_p50_ms",
  "input_to_visible_p95_ms", "input_to_visible_p99_ms", "render_p50_ms", "render_p95_ms",
  "render_p99_ms",
] as const;

type TerminalNumbers = {
  windowMs: number; inputCount: number; outputCount: number; presentedCount: number;
  correlatedOutputCount: number; droppedCount: number; outputBytes: number; maxQueueDepth: number;
  inputToOutputP50Ms: number; inputToOutputP95Ms: number; inputToOutputP99Ms: number;
  inputToVisibleP50Ms: number; inputToVisibleP95Ms: number; inputToVisibleP99Ms: number;
  renderP50Ms: number; renderP95Ms: number; renderP99Ms: number; inputFailedCount?: number;
};

function parseTerminalNumbers(properties: Record<string, unknown>): TerminalNumbers | null {
  const values = Object.fromEntries(terminalNumericKeys.map((key) => [key, unsignedInteger(properties[key])])) as Record<string, number | null>;
  if (Object.values(values).some((value) => value === null)) return null;
  const failed = properties.input_failed_count === undefined ? undefined : unsignedInteger(properties.input_failed_count);
  if (failed === null) return null;
  return {
    windowMs: values.window_ms!, inputCount: values.input_count!, outputCount: values.output_count!,
    presentedCount: values.presented_count!, correlatedOutputCount: values.correlated_output_count!,
    droppedCount: values.dropped_count!, outputBytes: values.output_bytes!, maxQueueDepth: values.max_queue_depth!,
    inputToOutputP50Ms: values.input_to_output_p50_ms!, inputToOutputP95Ms: values.input_to_output_p95_ms!,
    inputToOutputP99Ms: values.input_to_output_p99_ms!, inputToVisibleP50Ms: values.input_to_visible_p50_ms!,
    inputToVisibleP95Ms: values.input_to_visible_p95_ms!, inputToVisibleP99Ms: values.input_to_visible_p99_ms!,
    renderP50Ms: values.render_p50_ms!, renderP95Ms: values.render_p95_ms!, renderP99Ms: values.render_p99_ms!,
    ...(failed === undefined ? {} : { inputFailedCount: failed }),
  };
}

function parseTerminalHistograms(properties: Record<string, unknown>): Record<string, string> | undefined | null {
  const names = ["input_to_output", "input_to_visible", "render"];
  const hasVersion = properties.histogram_version !== undefined;
  if (!hasVersion && names.some((name) => properties[`${name}_histogram`] !== undefined)) return null;
  if (!hasVersion) return undefined;
  if (properties.histogram_version !== 1) return null;
  const histograms: Record<string, string> = {};
  for (const name of names) {
    const raw = properties[`${name}_histogram`];
    if (typeof raw !== "string" || raw.length > 512) return null;
    try {
      const counts: unknown = JSON.parse(raw);
      if (!Array.isArray(counts) || counts.length !== 17 || counts.some((n) => unsignedInteger(n) === null)) return null;
      histograms[name] = JSON.stringify(counts);
    } catch { return null; }
  }
  return histograms;
}

export function parseMobileTerminalLatencyAnomaly(candidate: unknown): MobileTerminalLatencyAnomaly | null {
  if (!isRecord(candidate) || candidate.event !== TERMINAL_ANOMALY_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const properties = candidate.properties;
  const metadata = parseMetadata(properties);
  const durationMs = unsignedInteger(properties.duration_ms);
  const thresholdMs = unsignedInteger(properties.threshold_ms);
  if (!metadata || durationMs === null || thresholdMs === null
    || typeof properties.stage !== "string"
    || !new Set(["input_to_output", "render"]).has(properties.stage)) return null;
  return {
    timestamp: candidate.timestamp,
    durationMs,
    thresholdMs,
    stage: properties.stage as MobileTerminalLatencyAnomaly["stage"],
    ...metadata,
  };
}

export function parseMobileObservabilityEvent(candidate: unknown): MobileObservabilityEvent | null {
  return parseMobileNetworkOutcome(candidate)
    ?? parseMobileTerminalLatencyWindow(candidate)
    ?? parseMobileTerminalLatencyAnomaly(candidate);
}

type CoreObservation = Pick<MobileNetworkOutcome, "phase" | "outcome" | "durationMs" | "userUsable" | "failure" | "transport">;
type Metadata = Pick<MobileNetworkOutcome, "platform" | "clientChannel" | "appVersion" | "buildNumber" | "bundleIdentifier" | "osVersion" | "deviceModel" | "traceId" | "operation" | "terminalPhase">;

function validTimestamp(value: unknown): value is string {
  return typeof value === "string"
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)
    && Number.isFinite(Date.parse(value));
}

function validProperties(properties: Record<string, unknown>): boolean {
  return !Object.keys(properties).some((key) => !allowedPropertyKeys.has(key));
}

function parseCore(properties: Record<string, unknown>): CoreObservation | null {
  if (typeof properties.phase !== "string" || !phases.has(properties.phase)) return null;
  if (typeof properties.outcome !== "string" || !outcomes.has(properties.outcome)) return null;
  if (properties.runtime_role !== undefined && properties.runtime_role !== RUNTIME_ROLE) return null;
  if (typeof properties.user_usable !== "boolean") return null;
  const durationMs = unsignedInteger(properties.duration_ms);
  const failure = optionalSetValue(properties.failure, failures);
  const transport = optionalSetValue(properties.transport, transports);
  if (durationMs === null || failure === false || transport === false) return null;
  return {
    phase: properties.phase,
    outcome: properties.outcome as CoreObservation["outcome"],
    durationMs,
    userUsable: properties.user_usable,
    ...(typeof failure === "string" ? { failure } : {}),
    ...(typeof transport === "string" ? { transport } : {}),
  };
}

function parseMetadata(properties: Record<string, unknown>): Metadata | null {
  const platform = optionalExact(properties.platform, "ios");
  const clientChannel = optionalSetValue(properties.client_channel, new Set(["dev", "nightly", "production", "unknown"])) as
    | MobileNetworkOutcome["clientChannel"]
    | false;
  const appVersion = optionalMachineString(properties.app_version);
  const buildNumber = optionalMachineString(properties.build_number);
  const bundleIdentifier = optionalMachineString(properties.bundle_identifier);
  const osVersion = optionalMachineString(properties.os_version);
  const deviceModel = optionalMachineString(properties.device_model, true);
  const traceId = optionalTraceID(properties.trace_id);
  const operation = optionalSetValue(properties.operation, new Set(["replay", "artifactScan", "artifactList"]));
  const terminalPhase = optionalSetValue(properties.terminal_phase, new Set([
    "applied", "failed", "discarded",
  ]));
  if ([platform, clientChannel, appVersion, buildNumber, bundleIdentifier, osVersion, deviceModel,
    traceId, operation, terminalPhase].includes(false)) return null;
  if (properties.phase === "terminal_trace"
    && (typeof traceId !== "string" || typeof operation !== "string" || typeof terminalPhase !== "string")) {
    return null;
  }
  return {
    ...(platform === "ios" ? { platform } : {}),
    ...(typeof clientChannel === "string" ? { clientChannel } : {}),
    ...(typeof appVersion === "string" ? { appVersion } : {}),
    ...(typeof buildNumber === "string" ? { buildNumber } : {}),
    ...(typeof bundleIdentifier === "string" ? { bundleIdentifier } : {}),
    ...(typeof osVersion === "string" ? { osVersion } : {}),
    ...(typeof deviceModel === "string" ? { deviceModel } : {}),
    ...(typeof traceId === "string" ? { traceId } : {}),
    ...(typeof operation === "string" ? { operation } : {}),
    ...(typeof terminalPhase === "string" ? { terminalPhase } : {}),
  };
}

/** Emits one fixed-name span per terminal connectivity phase into Axiom. */
export async function emitMobileNetworkOutcomes(
  userId: string,
  batch: readonly MobileNetworkOutcome[],
): Promise<void> {
  await Promise.all(batch.map((observation) => withSpan(
    "cmux-mobile-network",
    "cmux.mobile.connectivity.latency",
    {
      "cmux.subsystem": "mobile-network",
      "cmux.runtime": "ios",
      "cmux.user_id": userId,
      "cmux.mobile.phase": observation.phase,
      "cmux.mobile.outcome": observation.outcome,
      "cmux.mobile.duration_ms": observation.durationMs,
      "cmux.mobile.user_usable": observation.userUsable,
      "cmux.mobile.occurred_at": observation.timestamp,
      "cmux.mobile.failure": observation.failure,
      "cmux.mobile.transport": observation.transport,
      "cmux.mobile.platform": observation.platform,
      "cmux.client.channel": observation.clientChannel,
      "cmux.mobile.app_version": observation.appVersion,
      "cmux.mobile.build_number": observation.buildNumber,
      "cmux.mobile.bundle_identifier": observation.bundleIdentifier,
      "cmux.mobile.os_version": observation.osVersion,
      "cmux.mobile.device_model": observation.deviceModel,
      "cmux.mobile.trace_id": observation.traceId,
      "cmux.mobile.operation": observation.operation,
      "cmux.mobile.terminal_phase": observation.terminalPhase,
    },
    (span) => {
      if (observation.outcome === "failure" || observation.outcome === "timeout") {
        span.setStatus({
          code: SpanStatusCode.ERROR,
          message: observation.failure ?? `${observation.phase}:${observation.outcome}`,
        });
      }
    },
  )));
}

export async function emitMobileObservabilityEvents(
  userId: string,
  batch: readonly MobileObservabilityEvent[],
): Promise<void> {
  await Promise.all(batch.map((observation) => {
    if ("phase" in observation) {
      return emitMobileNetworkOutcomes(userId, [observation]);
    }
    if ("windowMs" in observation) {
      return withSpan(
        "cmux-mobile-network",
        "cmux.mobile.terminal.latency",
        {
          "cmux.subsystem": "mobile-network",
          "cmux.runtime": "ios",
          "cmux.user_id": userId,
          "cmux.mobile.terminal.event": "window",
          "cmux.mobile.terminal.window_ms": observation.windowMs,
          "cmux.mobile.terminal.input_failed_count": observation.inputFailedCount,
          "cmux.mobile.terminal.histogram_version": observation.histograms ? 1 : undefined,
          ...Object.fromEntries(Object.entries(observation.histograms ?? {}).map(([name, counts]) => [`cmux.mobile.terminal.${name}_histogram`, counts])),
          "cmux.mobile.terminal.input_count": observation.inputCount,
          "cmux.mobile.terminal.output_count": observation.outputCount,
          "cmux.mobile.terminal.presented_count": observation.presentedCount,
          "cmux.mobile.terminal.correlated_output_count": observation.correlatedOutputCount,
          "cmux.mobile.terminal.dropped_count": observation.droppedCount,
          "cmux.mobile.terminal.output_bytes": observation.outputBytes,
          "cmux.mobile.terminal.max_queue_depth": observation.maxQueueDepth,
          "cmux.mobile.terminal.input_to_output_p50_ms": observation.inputToOutputP50Ms,
          "cmux.mobile.terminal.input_to_output_p95_ms": observation.inputToOutputP95Ms,
          "cmux.mobile.terminal.input_to_output_p99_ms": observation.inputToOutputP99Ms,
          "cmux.mobile.terminal.input_to_visible_p50_ms": observation.inputToVisibleP50Ms,
          "cmux.mobile.terminal.input_to_visible_p95_ms": observation.inputToVisibleP95Ms,
          "cmux.mobile.terminal.input_to_visible_p99_ms": observation.inputToVisibleP99Ms,
          "cmux.mobile.terminal.render_p50_ms": observation.renderP50Ms,
          "cmux.mobile.terminal.render_p95_ms": observation.renderP95Ms,
          "cmux.mobile.terminal.render_p99_ms": observation.renderP99Ms,
          "cmux.mobile.occurred_at": observation.timestamp,
          "cmux.mobile.platform": observation.platform,
          "cmux.client.channel": observation.clientChannel,
          "cmux.mobile.app_version": observation.appVersion,
          "cmux.mobile.build_number": observation.buildNumber,
          "cmux.mobile.bundle_identifier": observation.bundleIdentifier,
          "cmux.mobile.os_version": observation.osVersion,
          "cmux.mobile.device_model": observation.deviceModel,
        },
        () => undefined,
      );
    }
    return withSpan(
      "cmux-mobile-network",
      "cmux.mobile.terminal.latency.anomaly",
      {
        "cmux.subsystem": "mobile-network",
        "cmux.runtime": "ios",
        "cmux.user_id": userId,
        "cmux.mobile.terminal.event": "anomaly",
        "cmux.mobile.terminal.stage": observation.stage,
        "cmux.mobile.terminal.duration_ms": observation.durationMs,
        "cmux.mobile.terminal.threshold_ms": observation.thresholdMs,
        "cmux.mobile.occurred_at": observation.timestamp,
        "cmux.mobile.platform": observation.platform,
        "cmux.client.channel": observation.clientChannel,
        "cmux.mobile.app_version": observation.appVersion,
        "cmux.mobile.build_number": observation.buildNumber,
        "cmux.mobile.bundle_identifier": observation.bundleIdentifier,
        "cmux.mobile.os_version": observation.osVersion,
        "cmux.mobile.device_model": observation.deviceModel,
      },
      (span) => span.setStatus({ code: SpanStatusCode.ERROR, message: `terminal:${observation.stage}` }),
    );
  }));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function unsignedInteger(value: unknown): number | null {
  return Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= MAX_SAFE_UNSIGNED_INTEGER
    ? Number(value)
    : null;
}

function optionalSetValue(value: unknown, allowed: ReadonlySet<string>): string | undefined | false {
  if (value === undefined) return undefined;
  return typeof value === "string" && allowed.has(value) ? value : false;
}

function optionalExact<T extends string>(value: unknown, expected: T): T | undefined | false {
  if (value === undefined) return undefined;
  return value === expected ? expected : false;
}

function optionalMachineString(value: unknown, allowSpaces = false): string | undefined | false {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_STRING_LENGTH) return false;
  const pattern = allowSpaces ? /^[A-Za-z0-9 .,_()+-]+$/ : /^[A-Za-z0-9._+-]+$/;
  return pattern.test(value) ? value : false;
}

function optionalTraceID(value: unknown): string | undefined | false {
  if (value === undefined) return undefined;
  return typeof value === "string" && /^[0-9a-f]{16}$/.test(value) && value !== "0000000000000000"
    ? value
    : false;
}
