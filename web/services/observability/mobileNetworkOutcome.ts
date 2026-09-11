import { SpanStatusCode } from "@opentelemetry/api";

import { withSpan } from "../telemetry";

export const MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES = 64 * 1_024;
export const MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS = 100;

const EVENT_NAME = "ios_connectivity_latency";
const RUNTIME_ROLE = "mobileClient";
const MAX_STRING_LENGTH = 120;
const MAX_SAFE_UNSIGNED_INTEGER = 0xffff_ffff;

const phases = new Set([
  "endpoint_start", "pairing", "transport_dial", "host_auth",
  "rpc_ready", "recovery", "relay_policy", "discovery",
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
  "failure", "transport", "platform", "app_version", "build_number",
  "bundle_identifier", "os_version", "device_model",
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
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

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

type CoreObservation = Pick<MobileNetworkOutcome, "phase" | "outcome" | "durationMs" | "userUsable" | "failure" | "transport">;
type Metadata = Pick<MobileNetworkOutcome, "platform" | "appVersion" | "buildNumber" | "bundleIdentifier" | "osVersion" | "deviceModel">;

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
  const appVersion = optionalMachineString(properties.app_version);
  const buildNumber = optionalMachineString(properties.build_number);
  const bundleIdentifier = optionalMachineString(properties.bundle_identifier);
  const osVersion = optionalMachineString(properties.os_version);
  const deviceModel = optionalMachineString(properties.device_model, true);
  if ([platform, appVersion, buildNumber, bundleIdentifier, osVersion, deviceModel].includes(false)) return null;
  return {
    ...(platform === "ios" ? { platform } : {}),
    ...(typeof appVersion === "string" ? { appVersion } : {}),
    ...(typeof buildNumber === "string" ? { buildNumber } : {}),
    ...(typeof bundleIdentifier === "string" ? { bundleIdentifier } : {}),
    ...(typeof osVersion === "string" ? { osVersion } : {}),
    ...(typeof deviceModel === "string" ? { deviceModel } : {}),
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
      "cmux.mobile.app_version": observation.appVersion,
      "cmux.mobile.build_number": observation.buildNumber,
      "cmux.mobile.bundle_identifier": observation.bundleIdentifier,
      "cmux.mobile.os_version": observation.osVersion,
      "cmux.mobile.device_model": observation.deviceModel,
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
