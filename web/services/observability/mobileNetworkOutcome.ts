import { SpanStatusCode } from "@opentelemetry/api";

import { withSpan } from "../telemetry";

export const MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES = 64 * 1_024;
export const MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS = 100;

const EVENT_NAME = "ios_connectivity_latency";
const IROH_PATH_EVENT_NAME = "ios_iroh_path_event";
const TASK_MODEL_EVENT_NAME = "ios_task_model_discovery";
const TASK_MODEL_RESULT_EVENT_NAME = "ios_task_model_result";
const TERMINAL_WINDOW_EVENT_NAME = "ios_terminal_latency_window";
const TERMINAL_ANOMALY_EVENT_NAME = "ios_terminal_latency_anomaly";
const RUNTIME_ROLE = "mobileClient";
const MAX_STRING_LENGTH = 120;
const MAX_SAFE_UNSIGNED_INTEGER = 0xffff_ffff;

const phases = new Set([
  "endpoint_start", "pairing", "transport_dial", "host_auth",
  "rpc_ready", "recovery", "relay_policy", "discovery", "initial_connect", "terminal_trace",
]);
const outcomes = new Set(["success", "failure", "timeout", "cancelled", "abandoned", "stalled"]);
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
const eventCodes = new Set([
  "pairOk", "pairFail", "pairUnreachable",
  "transportDialConnected", "transportDialFailed", "transportDialCancelled",
  "hostAuthenticated", "hostAuthenticationFailed", "rpcReady", "rpcFailed",
  "recoverySucceeded", "recoveryFailed", "endpointActive", "endpointFailed",
  "relayPolicyRefreshSucceeded", "relayPolicyRefreshFailed",
  "discoverySucceeded", "discoveryFailed", "selectedPathChanged", "transportPathEvent",
]);
const cancellationReasons = new Set([
  "unknown", "requestCancelled", "requestTimedOut", "sessionTeardown", "sessionDeinitialized",
]);
const taskModelProviders = new Set(["claude", "codex", "opencode"]);
const taskModelSources = new Set(["discovered", "backend", "augmented", "fallback"]);
const irohPathOperations = new Set(["opened", "closed", "selected", "lagged", "snapshot"]);
const irohPathKinds = new Set(["unknown", "direct", "relay", "private_network", "loopback"]);
const irohPathKindsByCode = new Map<number, string>([
  [0, "unknown"], [1, "direct"], [2, "relay"], [3, "private_network"], [4, "loopback"],
]);
const irohPathOperationsByCode = new Map<number, string>([
  [1, "opened"], [2, "closed"], [3, "selected"], [4, "lagged"],
]);
const metadataOperations = new Set(["replay", "artifactScan", "artifactList", "model_list"]);
const irohPathPropertyKeys = new Set(["path"]);
const noAdditionalPropertyKeys = new Set<string>();

// Per-hop stages and pacer state the phone adds to a latency window only when
// that window measured them (Macs that stamp frames with host timing).
const optionalTerminalStageNames = [
  "host_accept", "host_capture", "host_dispatch",
  "network_round_trip", "uplink", "downlink", "pacer_period",
] as const;
const optionalTerminalCountKeys = [
  "pacer_sample_count", "pacer_emitted_count", "pacer_coalesced_count",
  "pacer_shed_count", "pacer_period_max_ms",
] as const;
const optionalTerminalNumericKeys = [
  ...optionalTerminalCountKeys,
  ...optionalTerminalStageNames.flatMap((name) => [`${name}_p50_ms`, `${name}_p95_ms`, `${name}_p99_ms`]),
];

const allowedPropertyKeys = new Set([
  ...optionalTerminalNumericKeys,
  ...optionalTerminalStageNames.map((name) => `${name}_histogram`),
  "phase", "outcome", "duration_ms", "runtime_role", "user_usable",
  "failure", "transport", "platform", "client_channel", "app_version", "build_number",
  "bundle_identifier", "os_version", "device_model",
  "population", "attempt_id", "terminal_ready",
  "event_code", "event_code_raw", "event_surface", "event_a", "event_b", "event_c",
  "cancellation_reason",
  "window_ms", "input_count", "output_count", "presented_count",
  "correlated_output_count", "dropped_count", "output_bytes", "max_queue_depth",
  "input_to_output_p50_ms", "input_to_output_p95_ms", "input_to_output_p99_ms",
  "input_to_visible_p50_ms", "input_to_visible_p95_ms", "input_to_visible_p99_ms",
  "render_p50_ms", "render_p95_ms", "render_p99_ms",
  "input_failed_count", "histogram_version", "input_to_output_histogram", "input_to_visible_histogram", "render_histogram",
  "duration_ms", "threshold_ms", "stage",
  "trace_id", "operation", "terminal_phase",
  "replay_trigger", "surface_blank", "barrier_active", "replay_attempt", "app_foreground",
  "model_count", "phase", "attempt", "retry_delay_ms", "stop_reason", "correlation_id",
  "provider", "source", "effort_count",
]);

export type MobileNetworkOutcome = {
  readonly timestamp: string;
  readonly phase: string;
  readonly outcome: "success" | "failure" | "timeout" | "cancelled" | "abandoned" | "stalled";
  readonly durationMs: number;
  readonly runtimeRole: "mobileClient";
  readonly userUsable: boolean;
  readonly population?: "cold_open" | "warm_open" | "reconnect" | "pairing_required";
  readonly attemptId?: string;
  readonly terminalReady?: boolean;
  readonly failure?: string;
  readonly transport?: string;
  /** Stable diagnostic vocabulary and bounded payload slots from the client. */
  readonly eventCode?: string;
  readonly eventCodeRaw?: number;
  readonly eventSurface?: number;
  readonly eventA?: number;
  readonly eventB?: number;
  readonly eventC?: number;
  readonly cancellationReason?: string;
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
  /** Why the replay this trace describes was requested. */
  readonly replayTrigger?: string;
  /** The surface had been rebuilt blank, so this stall is a blank screen. */
  readonly surfaceBlank?: boolean;
  /** A replay barrier was suppressing live output for the surface. */
  readonly barrierActive?: boolean;
  /** Zero-based retry index within the replay episode. */
  readonly replayAttempt?: number;
  /**
   * Whether the app was on screen when this phase was recorded. A suspended
   * app runs no code, so elapsed time that spans suspension was never spent
   * waiting on screen; percentiles that mix the two are meaningless.
   */
  readonly appForeground?: boolean;
};

export type MobileIrohPathEvent = {
  readonly timestamp: string;
  readonly operation: "opened" | "closed" | "selected" | "lagged" | "snapshot";
  readonly path: "unknown" | "direct" | "relay" | "private_network" | "loopback";
  readonly transport: "iroh";
  readonly eventCode: "selectedPathChanged" | "transportPathEvent";
  readonly eventCodeRaw: number;
  readonly eventSurface?: number;
  readonly eventA?: number;
  readonly eventB?: number;
  readonly eventC?: number;
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export type MobileTerminalLatencyWindow = {
  readonly timestamp: string;
  readonly windowMs: number;
  readonly inputFailedCount?: number;
  readonly histograms?: Readonly<Record<string, string>>;
  /** Per-hop stage percentiles and pacer counters, present only when measured. */
  readonly stageMetrics?: Readonly<Record<string, number>>;
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

export type MobileTaskModelDiscovery = {
  readonly timestamp: string;
  readonly outcome: "success" | "failure";
  readonly durationMs: number;
  readonly modelCount: number;
  readonly correlationId?: number;
  readonly discoveryPhase?: "retry_scheduled" | "retry_stopped";
  readonly attempt?: number;
  readonly retryDelayMs?: number;
  readonly stopReason?: "unsupported" | "disabled" | "authorizationRequired" | "accountMismatch" | "invalidRequest" | "providerUnavailable" | "cancelled";
  readonly failure?: string;
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export type MobileTaskModelResult = {
  readonly timestamp: string;
  readonly provider: "claude" | "codex" | "opencode";
  readonly source: "discovered" | "backend" | "augmented" | "fallback";
  readonly effortCount: number;
  readonly correlationId?: number;
  readonly platform?: "ios";
  readonly clientChannel?: "dev" | "nightly" | "production" | "unknown";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export type MobileObservabilityEvent = MobileNetworkOutcome | MobileIrohPathEvent | MobileTerminalLatencyWindow | MobileTerminalLatencyAnomaly | MobileTaskModelDiscovery | MobileTaskModelResult;

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

function parseMobileIrohPathEvent(candidate: unknown): MobileIrohPathEvent | null {
  if (!isRecord(candidate) || candidate.event !== IROH_PATH_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties, irohPathPropertyKeys)) return null;
  const properties = candidate.properties;
  const operation = optionalSetValue(properties.operation, irohPathOperations);
  const path = optionalSetValue(properties.path, irohPathKinds);
  const transport = optionalSetValue(properties.transport, new Set(["iroh"]));
  const diagnostics = parseDiagnosticFields(properties);
  const metadata = parseMetadata(properties, irohPathOperations);
  if (typeof operation !== "string" || typeof path !== "string" || transport !== "iroh"
    || !diagnostics || typeof diagnostics.eventCodeRaw !== "number" || !metadata
    || !consistentIrohPathFields(diagnostics, operation, path)) return null;
  return {
    timestamp: candidate.timestamp,
    operation: operation as MobileIrohPathEvent["operation"],
    path: path as MobileIrohPathEvent["path"],
    transport,
    eventCode: diagnostics.eventCode as MobileIrohPathEvent["eventCode"],
    eventCodeRaw: diagnostics.eventCodeRaw,
    ...(typeof diagnostics.eventSurface === "number" ? { eventSurface: diagnostics.eventSurface } : {}),
    ...(typeof diagnostics.eventA === "number" ? { eventA: diagnostics.eventA } : {}),
    ...(typeof diagnostics.eventB === "number" ? { eventB: diagnostics.eventB } : {}),
    ...(typeof diagnostics.eventC === "number" ? { eventC: diagnostics.eventC } : {}),
    ...pathMetadataFields(metadata),
  };
}

function consistentIrohPathFields(
  diagnostics: Pick<CoreObservation, "eventCode" | "eventCodeRaw" | "eventA" | "eventB">,
  operation: string,
  path: string,
): boolean {
  if (diagnostics.eventCode === "selectedPathChanged") {
    return diagnostics.eventCodeRaw === 40 && operation === "snapshot"
      && irohPathKindsByCode.get(diagnostics.eventA ?? -1) === path;
  }
  return diagnostics.eventCode === "transportPathEvent" && diagnostics.eventCodeRaw === 55
    && irohPathOperationsByCode.get(diagnostics.eventA ?? -1) === operation
    && irohPathKindsByCode.get(diagnostics.eventB ?? -1) === path
    && (operation !== "lagged" || path === "unknown");
}

function parseMobileTerminalLatencyWindow(candidate: unknown): MobileTerminalLatencyWindow | null {
  if (!isRecord(candidate) || candidate.event !== TERMINAL_WINDOW_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const properties = candidate.properties;
  const metadata = parseMetadata(properties);
  const numbers = parseTerminalNumbers(properties);
  const histograms = parseTerminalHistograms(properties);
  const stageMetrics = parseOptionalTerminalMetrics(properties);
  if (!metadata || !numbers || histograms === null || stageMetrics === null) return null;
  return {
    timestamp: candidate.timestamp,
    ...numbers,
    ...(histograms ? { histograms } : {}),
    ...(stageMetrics ? { stageMetrics } : {}),
    ...metadata,
  };
}

function parseOptionalTerminalMetrics(properties: Record<string, unknown>): Record<string, number> | undefined | null {
  const metrics: Record<string, number> = {};
  for (const key of optionalTerminalNumericKeys) {
    if (properties[key] === undefined) continue;
    const value = unsignedInteger(properties[key]);
    if (value === null) return null;
    metrics[key] = value;
  }
  return Object.keys(metrics).length > 0 ? metrics : undefined;
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
  const present = optionalTerminalStageNames.filter((name) => properties[`${name}_histogram`] !== undefined);
  for (const name of [...names, ...present]) {
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

function parseMobileTerminalLatencyAnomaly(candidate: unknown): MobileTerminalLatencyAnomaly | null {
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
  return parseMobileIrohPathEvent(candidate)
    ?? parseMobileTaskModelResult(candidate)
    ?? parseMobileTaskModelDiscovery(candidate)
    ?? parseMobileNetworkOutcome(candidate)
    ?? parseMobileTerminalLatencyWindow(candidate)
    ?? parseMobileTerminalLatencyAnomaly(candidate);
}

type MobileTaskModelDiscoveryPayload = Pick<MobileTaskModelDiscovery, "outcome" | "durationMs" | "modelCount" | "correlationId" | "failure">;
type MobileTaskModelRetryMetadata = Pick<MobileTaskModelDiscovery, "discoveryPhase" | "attempt" | "retryDelayMs" | "stopReason">;

const taskModelRetryPhases = new Set(["retry_scheduled", "retry_stopped"]);
const taskModelStopReasons = new Set([
  "unsupported", "disabled", "authorizationRequired", "accountMismatch",
  "invalidRequest", "providerUnavailable", "cancelled",
]);

function parseMobileTaskModelDiscoveryPayload(
  properties: Record<string, unknown>,
): MobileTaskModelDiscoveryPayload | null {
  if (properties.operation !== "model_list") return null;
  if (properties.outcome !== "success" && properties.outcome !== "failure") return null;
  const durationMs = unsignedInteger(properties.duration_ms);
  const modelCount = unsignedInteger(properties.model_count);
  const correlationId = properties.correlation_id === undefined
    ? undefined
    : unsignedInteger(properties.correlation_id);
  const failure = optionalSetValue(properties.failure, failures);
  if (durationMs === null || modelCount === null || correlationId === null || failure === false) return null;
  if (properties.outcome === "failure" && typeof failure !== "string") return null;
  return {
    outcome: properties.outcome,
    durationMs,
    modelCount,
    ...(typeof correlationId === "number" ? { correlationId } : {}),
    ...(typeof failure === "string" ? { failure } : {}),
  };
}

function parseMobileTaskModelRetryMetadata(
  properties: Record<string, unknown>,
): MobileTaskModelRetryMetadata | null {
  const phase = optionalSetValue(properties.phase, taskModelRetryPhases) as
    | MobileTaskModelDiscovery["discoveryPhase"] | false | undefined;
  const attempt = properties.attempt === undefined ? undefined : unsignedInteger(properties.attempt);
  const retryDelayMs = properties.retry_delay_ms === undefined ? undefined : unsignedInteger(properties.retry_delay_ms);
  const stopReason = optionalSetValue(properties.stop_reason, taskModelStopReasons) as
    | MobileTaskModelDiscovery["stopReason"] | false | undefined;
  if (phase === false || stopReason === false || attempt === null || retryDelayMs === null) return null;
  if (phase === "retry_scheduled" && (attempt === undefined || retryDelayMs === undefined)) return null;
  if (phase === "retry_stopped" && typeof stopReason !== "string") return null;
  if (phase === undefined && (attempt !== undefined || retryDelayMs !== undefined || stopReason !== undefined)) return null;
  return {
    ...(typeof phase === "string" ? { discoveryPhase: phase } : {}),
    ...(typeof attempt === "number" ? { attempt } : {}),
    ...(typeof retryDelayMs === "number" ? { retryDelayMs } : {}),
    ...(typeof stopReason === "string" ? { stopReason } : {}),
  };
}

function parseMobileTaskModelDiscovery(candidate: unknown): MobileTaskModelDiscovery | null {
  if (!isRecord(candidate) || candidate.event !== TASK_MODEL_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const payload = parseMobileTaskModelDiscoveryPayload(candidate.properties);
  const metadata = parseMetadata(candidate.properties);
  const retryMetadata = parseMobileTaskModelRetryMetadata(candidate.properties);
  if (!payload || !metadata || !retryMetadata) return null;
  return {
    timestamp: candidate.timestamp,
    ...payload,
    ...retryMetadata,
    ...(metadata.platform ? { platform: metadata.platform } : {}),
    ...(metadata.clientChannel ? { clientChannel: metadata.clientChannel } : {}),
    ...(metadata.appVersion ? { appVersion: metadata.appVersion } : {}),
    ...(metadata.buildNumber ? { buildNumber: metadata.buildNumber } : {}),
    ...(metadata.bundleIdentifier ? { bundleIdentifier: metadata.bundleIdentifier } : {}),
    ...(metadata.osVersion ? { osVersion: metadata.osVersion } : {}),
    ...(metadata.deviceModel ? { deviceModel: metadata.deviceModel } : {}),
  };
}

function parseMobileTaskModelResult(candidate: unknown): MobileTaskModelResult | null {
  if (!isRecord(candidate) || candidate.event !== TASK_MODEL_RESULT_EVENT_NAME || !isRecord(candidate.properties)) return null;
  if (!validTimestamp(candidate.timestamp) || !validProperties(candidate.properties)) return null;
  const payload = parseMobileTaskModelResultPayload(candidate.properties);
  if (!payload) return null;
  return {
    timestamp: candidate.timestamp,
    ...payload,
  };
}

type MobileTaskModelResultPayload = Omit<MobileTaskModelResult, "timestamp">;

function parseMobileTaskModelResultPayload(
  properties: Record<string, unknown>,
): MobileTaskModelResultPayload | null {
  if (properties.operation !== "model_list") return null;
  const provider = optionalSetValue(properties.provider, taskModelProviders);
  const source = optionalSetValue(properties.source, taskModelSources);
  if (typeof provider !== "string" || typeof source !== "string") return null;
  const effortCount = unsignedInteger(properties.effort_count);
  if (effortCount === null) return null;
  const correlationId = optionalUnsignedInteger(properties.correlation_id);
  if (correlationId === null) return null;
  const metadata = parseMetadata(properties);
  if (!metadata) return null;
  return {
    provider: provider as MobileTaskModelResult["provider"],
    source: source as MobileTaskModelResult["source"],
    effortCount,
    ...(typeof correlationId === "number" ? { correlationId } : {}),
    ...taskModelMetadataFields(metadata),
  };
}

function taskModelMetadataFields(metadata: Metadata): Omit<MobileTaskModelResultPayload, "provider" | "source" | "effortCount" | "correlationId"> {
  return {
    ...(metadata.platform ? { platform: metadata.platform } : {}),
    ...(metadata.clientChannel ? { clientChannel: metadata.clientChannel } : {}),
    ...(metadata.appVersion ? { appVersion: metadata.appVersion } : {}),
    ...(metadata.buildNumber ? { buildNumber: metadata.buildNumber } : {}),
    ...(metadata.bundleIdentifier ? { bundleIdentifier: metadata.bundleIdentifier } : {}),
    ...(metadata.osVersion ? { osVersion: metadata.osVersion } : {}),
    ...(metadata.deviceModel ? { deviceModel: metadata.deviceModel } : {}),
  };
}

function pathMetadataFields(metadata: Metadata): Pick<
  MobileIrohPathEvent,
  "platform" | "clientChannel" | "appVersion" | "buildNumber" | "bundleIdentifier" | "osVersion" | "deviceModel"
> {
  return {
    ...(metadata.platform ? { platform: metadata.platform } : {}),
    ...(metadata.clientChannel ? { clientChannel: metadata.clientChannel } : {}),
    ...(metadata.appVersion ? { appVersion: metadata.appVersion } : {}),
    ...(metadata.buildNumber ? { buildNumber: metadata.buildNumber } : {}),
    ...(metadata.bundleIdentifier ? { bundleIdentifier: metadata.bundleIdentifier } : {}),
    ...(metadata.osVersion ? { osVersion: metadata.osVersion } : {}),
    ...(metadata.deviceModel ? { deviceModel: metadata.deviceModel } : {}),
  };
}

type CoreObservation = Pick<MobileNetworkOutcome, "phase" | "outcome" | "durationMs" | "userUsable" | "failure" | "transport" | "population" | "attemptId" | "terminalReady" | "eventCode" | "eventCodeRaw" | "eventSurface" | "eventA" | "eventB" | "eventC" | "cancellationReason">;
type Metadata = Pick<MobileNetworkOutcome, "platform" | "clientChannel" | "appVersion" | "buildNumber" | "bundleIdentifier" | "osVersion" | "deviceModel" | "traceId" | "operation" | "terminalPhase" | "replayTrigger" | "surfaceBlank" | "barrierActive" | "replayAttempt" | "appForeground">;

/** Mirrors `MobileTerminalReplayTrigger` in CMUXMobileCore. */
const replayTriggers = new Set([
  "unknown", "outputReset", "renderPipelineReset", "viewportTransition",
  "revisionChainBreak", "historyChainBreak", "coldAttach", "failureRetry",
  "droppedFrame", "applyFenceFailure", "pendingInputDrop", "resubscribe",
  "screenTransition", "missingBaseline", "byteGap",
]);

function validTimestamp(value: unknown): value is string {
  return typeof value === "string"
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)
    && Number.isFinite(Date.parse(value));
}

function validProperties(
  properties: Record<string, unknown>,
  additionalKeys: ReadonlySet<string> = noAdditionalPropertyKeys,
): boolean {
  return !Object.keys(properties).some((key) => !allowedPropertyKeys.has(key) && !additionalKeys.has(key));
}

function optionalUnsignedInteger(value: unknown): number | null | undefined {
  return value === undefined ? undefined : unsignedInteger(value);
}

function parseCore(properties: Record<string, unknown>): CoreObservation | null {
  if (typeof properties.phase !== "string" || !phases.has(properties.phase)) return null;
  if (typeof properties.outcome !== "string" || !outcomes.has(properties.outcome)) return null;
  if (properties.runtime_role !== undefined && properties.runtime_role !== RUNTIME_ROLE) return null;
  if (typeof properties.user_usable !== "boolean") return null;
  const durationMs = unsignedInteger(properties.duration_ms);
  const failure = optionalSetValue(properties.failure, failures);
  const transport = optionalSetValue(properties.transport, transports);
  const initialFields = parseInitialConnectionFields(properties);
  const diagnosticFields = parseDiagnosticFields(properties);
  if (durationMs === null || failure === false || transport === false || initialFields === null
    || diagnosticFields === null) return null;
  return {
    phase: properties.phase,
    outcome: properties.outcome as CoreObservation["outcome"],
    durationMs,
    userUsable: properties.user_usable,
    ...(typeof failure === "string" ? { failure } : {}),
    ...(typeof transport === "string" ? { transport } : {}),
    ...initialFields,
    ...diagnosticFields,
  };
}

function parseDiagnosticFields(
  properties: Record<string, unknown>,
): Pick<CoreObservation, "eventCode" | "eventCodeRaw" | "eventSurface" | "eventA" | "eventB" | "eventC" | "cancellationReason"> | null {
  const eventCode = optionalSetValue(properties.event_code, eventCodes);
  const eventCodeRaw = optionalDiagnosticInteger(properties.event_code_raw, 0xffff);
  const eventSurface = optionalDiagnosticInteger(properties.event_surface);
  const eventA = optionalDiagnosticInteger(properties.event_a);
  const eventB = optionalDiagnosticInteger(properties.event_b);
  const eventC = optionalDiagnosticInteger(properties.event_c);
  const cancellationReason = optionalSetValue(properties.cancellation_reason, cancellationReasons);
  if ([eventCode, eventCodeRaw, eventSurface, eventA, eventB, eventC, cancellationReason].includes(false)) return null;
  return {
    ...(typeof eventCode === "string" ? { eventCode } : {}),
    ...(typeof eventCodeRaw === "number" ? { eventCodeRaw } : {}),
    ...(typeof eventSurface === "number" ? { eventSurface } : {}),
    ...(typeof eventA === "number" ? { eventA } : {}),
    ...(typeof eventB === "number" ? { eventB } : {}),
    ...(typeof eventC === "number" ? { eventC } : {}),
    ...(typeof cancellationReason === "string" ? { cancellationReason } : {}),
  };
}

function parseInitialConnectionFields(
  properties: Record<string, unknown>,
): Pick<CoreObservation, "population" | "attemptId" | "terminalReady"> | null {
  const population = optionalSetValue(
    properties.population,
    new Set(["cold_open", "warm_open", "reconnect", "pairing_required"]),
  ) as CoreObservation["population"] | false;
  const attemptId = properties.attempt_id === undefined
    ? undefined
    : optionalMachineString(properties.attempt_id);
  const terminalReady = properties.terminal_ready === undefined
    ? undefined
    : typeof properties.terminal_ready === "boolean" ? properties.terminal_ready : false;
  if (population === false || attemptId === false || terminalReady === false) return null;
  return {
    ...(typeof population === "string" ? { population } : {}),
    ...(typeof attemptId === "string" ? { attemptId } : {}),
    ...(typeof terminalReady === "boolean" ? { terminalReady } : {}),
  };
}

/// Categorical context for a replay trace. Split out of `parseMetadata` to
/// keep that function under the repository complexity limit.
function parseReplayContextFields(
  properties: Record<string, unknown>,
): Pick<Metadata, "replayTrigger" | "surfaceBlank" | "barrierActive" | "replayAttempt" | "appForeground"> | null {
  const replayTrigger = optionalSetValue(properties.replay_trigger, replayTriggers);
  const surfaceBlank = optionalBoolean(properties.surface_blank);
  const barrierActive = optionalBoolean(properties.barrier_active);
  const appForeground = optionalBoolean(properties.app_foreground);
  const replayAttempt = optionalDiagnosticInteger(properties.replay_attempt, 0xff);
  if (replayTrigger === false || replayAttempt === false) return null;
  if (surfaceBlank === null || barrierActive === null || appForeground === null) return null;
  return {
    ...(typeof replayTrigger === "string" ? { replayTrigger } : {}),
    ...(typeof surfaceBlank === "boolean" ? { surfaceBlank } : {}),
    ...(typeof barrierActive === "boolean" ? { barrierActive } : {}),
    ...(typeof replayAttempt === "number" ? { replayAttempt } : {}),
    ...(typeof appForeground === "boolean" ? { appForeground } : {}),
  };
}

function parseMetadata(
  properties: Record<string, unknown>,
  operations: ReadonlySet<string> = metadataOperations,
): Metadata | null {
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
  const operation = optionalSetValue(properties.operation, operations);
  const terminalPhase = optionalSetValue(properties.terminal_phase, new Set([
    "applied", "failed", "discarded", "hostCaptureFinished", "stalled",
  ]));
  const replayFields = parseReplayContextFields(properties);
  if ([platform, clientChannel, appVersion, buildNumber, bundleIdentifier, osVersion, deviceModel,
    traceId, operation, terminalPhase].includes(false) || replayFields === null) return null;
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
    ...replayFields,
    ...(typeof terminalPhase === "string" ? { terminalPhase } : {}),
  };
}

/** Emits one fixed-name span per terminal connectivity phase into Axiom. */
async function emitMobileNetworkOutcomes(
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
      "cmux.mobile.population": observation.population,
      "cmux.mobile.attempt_id": observation.attemptId,
      "cmux.mobile.terminal_ready": observation.terminalReady,
      "cmux.mobile.occurred_at": observation.timestamp,
      "cmux.mobile.failure": observation.failure,
      "cmux.mobile.transport": observation.transport,
      "cmux.mobile.event_code": observation.eventCode,
      "cmux.mobile.event_code_raw": observation.eventCodeRaw,
      "cmux.mobile.event_surface": observation.eventSurface,
      "cmux.mobile.event_a": observation.eventA,
      "cmux.mobile.event_b": observation.eventB,
      "cmux.mobile.event_c": observation.eventC,
      "cmux.mobile.cancellation_reason": observation.cancellationReason,
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
      "cmux.mobile.replay_trigger": observation.replayTrigger,
      "cmux.mobile.surface_blank": observation.surfaceBlank,
      "cmux.mobile.barrier_active": observation.barrierActive,
      "cmux.mobile.replay_attempt": observation.replayAttempt,
      "cmux.mobile.app_foreground": observation.appForeground,
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
    if ("path" in observation) {
      return withSpan(
        "cmux-mobile-network",
        "cmux.mobile.iroh.path",
        {
          "cmux.subsystem": "mobile-network",
          "cmux.runtime": "ios",
          "cmux.user_id": userId,
          "cmux.mobile.event": "iroh_path",
          "cmux.observation.source": "client",
          "cmux.mobile.transport": observation.transport,
          "cmux.mobile.path_operation": observation.operation,
          "cmux.mobile.path": observation.path,
          "cmux.mobile.event_code": observation.eventCode,
          "cmux.mobile.event_code_raw": observation.eventCodeRaw,
          "cmux.mobile.event_surface": observation.eventSurface,
          "cmux.mobile.event_a": observation.eventA,
          "cmux.mobile.event_b": observation.eventB,
          "cmux.mobile.event_c": observation.eventC,
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
    if ("provider" in observation) {
      return withSpan(
        "cmux-mobile-network",
        "cmux.mobile.task_model_result",
        {
          "cmux.subsystem": "mobile-network",
          "cmux.runtime": "ios",
          "cmux.user_id": userId,
          "cmux.mobile.event": "task_model_result",
          "cmux.mobile.operation": "model_list",
          "cmux.mobile.provider": observation.provider,
          "cmux.mobile.source": observation.source,
          "cmux.mobile.effort_count": observation.effortCount,
          "cmux.mobile.correlation_id": observation.correlationId,
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
    if ("modelCount" in observation) {
      return withSpan(
        "cmux-mobile-network",
        "cmux.mobile.task.model_discovery",
        {
          "cmux.subsystem": "mobile-network",
          "cmux.runtime": "ios",
          "cmux.user_id": userId,
          "cmux.mobile.event": "task_model_discovery",
          "cmux.mobile.outcome": observation.outcome,
          "cmux.mobile.duration_ms": observation.durationMs,
          "cmux.mobile.model_count": observation.modelCount,
          "cmux.mobile.correlation_id": observation.correlationId,
          "cmux.mobile.discovery_phase": observation.discoveryPhase,
          "cmux.mobile.attempt": observation.attempt,
          "cmux.mobile.retry_delay_ms": observation.retryDelayMs,
          "cmux.mobile.stop_reason": observation.stopReason,
          "cmux.mobile.failure": observation.failure,
          "cmux.mobile.occurred_at": observation.timestamp,
          "cmux.mobile.platform": observation.platform,
          "cmux.client.channel": observation.clientChannel,
          "cmux.mobile.app_version": observation.appVersion,
          "cmux.mobile.build_number": observation.buildNumber,
          "cmux.mobile.bundle_identifier": observation.bundleIdentifier,
          "cmux.mobile.os_version": observation.osVersion,
          "cmux.mobile.device_model": observation.deviceModel,
        },
        (span) => {
          if (observation.outcome === "failure") {
            span.setStatus({
              code: SpanStatusCode.ERROR,
              message: observation.failure ?? "task_model_discovery:failure",
            });
          }
        },
      );
    }
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
          ...Object.fromEntries(Object.entries(observation.stageMetrics ?? {}).map(([key, value]) => [`cmux.mobile.terminal.${key}`, value])),
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

function optionalDiagnosticInteger(value: unknown, maximum = 0xffff_ffff): number | undefined | false {
  if (value === undefined) return undefined;
  const parsed = unsignedInteger(value);
  return parsed === null || parsed > maximum ? false : parsed;
}

/// `false` is a legitimate value here, so an invalid one reports `null`
/// rather than joining the `false`-means-rejected convention used by the
/// string and integer helpers.
function optionalBoolean(value: unknown): boolean | undefined | null {
  if (value === undefined) return undefined;
  return typeof value === "boolean" ? value : null;
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
