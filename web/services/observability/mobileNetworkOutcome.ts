import { SpanStatusCode } from "@opentelemetry/api";

import { withSpan } from "../telemetry";

export const MAX_MOBILE_NETWORK_OUTCOME_REQUEST_BYTES = 64 * 1_024;
export const MAX_MOBILE_NETWORK_OUTCOME_BATCH_EVENTS = 100;

const EVENT_NAME = "ios_network_outcome";
const RUNTIME_ROLE = "mobileClient";
const MAX_STRING_LENGTH = 120;
const MAX_SAFE_UNSIGNED_INTEGER = 0xffff_ffff;

const eventNames = new Map<number, string>([
  [1, "connect"],
  [2, "pairOk"],
  [3, "pairFail"],
  [4, "renderGridLag"],
  [5, "livenessResubscribe"],
  [6, "streamEnded"],
  [7, "inputSeqBehind"],
  [8, "byteGap"],
  [9, "error"],
  [10, "pairUnreachable"],
  [25, "transportDialStarted"],
  [26, "transportDialConnected"],
  [27, "transportDialFailed"],
  [28, "hostAuthenticated"],
  [29, "rpcReady"],
  [30, "recoveryStarted"],
  [31, "recoverySucceeded"],
  [32, "recoveryFailed"],
  [33, "endpointStarting"],
  [34, "endpointActive"],
  [35, "endpointStopped"],
  [36, "endpointFailed"],
  [37, "relayPolicyRefreshStarted"],
  [38, "relayPolicyRefreshSucceeded"],
  [39, "relayPolicyRefreshFailed"],
  [40, "selectedPathChanged"],
  [41, "sessionClosed"],
  [42, "routeUnavailable"],
  [43, "retryScheduled"],
  [44, "discoveryStarted"],
  [45, "discoverySucceeded"],
  [46, "discoveryFailed"],
  [47, "admissionSucceeded"],
  [48, "admissionFailed"],
  [49, "hostAuthenticationFailed"],
  [50, "rpcFailed"],
  [51, "transportSessionLifecycle"],
  [52, "appLifecycleChanged"],
  [53, "reachabilityChanged"],
  [54, "transportCloseAttribution"],
  [55, "transportPathEvent"],
  [65, "appFeatureAction"],
  [71, "transportDialPlanBuilt"],
  [72, "transportPrivateAddressJoin"],
  [73, "transportLANDiscovery"],
  [74, "transportDialLegSucceeded"],
  [75, "transportDialLegFailed"],
  [76, "lanPublicationState"],
  [77, "transportDialSessionLinked"],
  [78, "transportDialCancelled"],
  [79, "transportCloseReason"],
]);

const operationNames = new Map<number, string>([
  [20, "authRestoreStarted"],
  [21, "authRestoreSucceeded"],
  [22, "authRestoreFailed"],
  [23, "authSignInStarted"],
  [24, "authCodeRequested"],
  [25, "authCodeRequestFailed"],
  [26, "authVerificationStarted"],
  [27, "authSignInSucceeded"],
  [28, "authSignInFailed"],
  [29, "authSignInCancelled"],
  [37, "authRevalidationStarted"],
  [38, "authRevalidationSucceeded"],
  [39, "authRevalidationFailed"],
  [64, "pushRemoteRegistrationRequested"],
  [65, "pushDeviceTokenReceived"],
  [66, "pushDeviceTokenRegistrationFailed"],
  [67, "pushBackendSyncStarted"],
  [68, "pushBackendSyncSucceeded"],
  [69, "pushBackendSyncFailed"],
  [100, "pairingStarted"],
  [101, "pairingSucceeded"],
  [102, "pairingFailed"],
  [103, "pairingCancelled"],
  [104, "computerListRefreshStarted"],
  [105, "computerListRefreshSucceeded"],
  [106, "computerListRefreshFailed"],
  [114, "computerRoutesUpdated"],
  [116, "tailscaleStatusChanged"],
  [117, "computerSwitchStarted"],
  [118, "computerSwitchSucceeded"],
  [119, "computerSwitchFailed"],
  [120, "reconnectStarted"],
  [121, "reconnectSucceeded"],
  [122, "reconnectFailed"],
  [123, "presenceStreamStarted"],
  [124, "presenceStreamUpdated"],
  [125, "presenceStreamFailed"],
  [126, "deviceRegistryLoadStarted"],
  [127, "deviceRegistryLoadSucceeded"],
  [128, "deviceRegistryLoadFailed"],
  [129, "connectionStateChanged"],
  [130, "workspaceListRefreshStarted"],
  [131, "workspaceListRefreshSucceeded"],
  [132, "workspaceListRefreshFailed"],
  [133, "workspaceStateSyncStarted"],
  [134, "workspaceStateSyncSucceeded"],
  [135, "workspaceStateSyncFailed"],
  [136, "workspaceStateSyncFellBack"],
  [137, "workspaceOpenStarted"],
  [138, "workspaceOpenSucceeded"],
  [139, "workspaceOpenFailed"],
  [202, "terminalStreamSubscribed"],
  [203, "terminalStreamResubscribed"],
  [204, "terminalStreamEnded"],
  [205, "terminalReplayStarted"],
  [206, "terminalReplaySucceeded"],
  [207, "terminalReplayFailed"],
  [208, "terminalReplayRetried"],
  [209, "terminalInputSubmitted"],
  [210, "terminalInputSent"],
  [211, "terminalInputAcknowledged"],
  [212, "terminalInputDropped"],
  [213, "terminalOutputReceived"],
  [214, "terminalOutputGapDetected"],
  [215, "terminalRenderLagDetected"],
  [217, "terminalViewportReportSucceeded"],
  [218, "terminalViewportReportFailed"],
  [220, "terminalScrollFailed"],
  [224, "terminalCreateStarted"],
  [225, "terminalCreateSucceeded"],
  [226, "terminalCreateFailed"],
  [531, "connectionMethodPreferenceChanged"],
  [612, "irohRelayPreferenceChangeStarted"],
  [613, "irohRelayPreferenceChangeSucceeded"],
  [614, "irohRelayPreferenceChangeFailed"],
  [615, "irohPathPreferenceChangeStarted"],
  [616, "irohPathPreferenceChangeSucceeded"],
  [617, "irohPathPreferenceChangeFailed"],
  [618, "irohCustomRelayUpsertStarted"],
  [619, "irohCustomRelayUpsertSucceeded"],
  [620, "irohCustomRelayUpsertFailed"],
  [621, "irohCustomRelayRemoveStarted"],
  [622, "irohCustomRelayRemoveSucceeded"],
  [623, "irohCustomRelayRemoveFailed"],
  [624, "irohCustomRelayTestStarted"],
  [625, "irohCustomRelayTestSucceeded"],
  [626, "irohCustomRelayTestFailed"],
  [627, "irohPrivatePathUpsertStarted"],
  [628, "irohPrivatePathUpsertSucceeded"],
  [629, "irohPrivatePathUpsertFailed"],
  [630, "irohPrivatePathRemoveStarted"],
  [631, "irohPrivatePathRemoveSucceeded"],
  [632, "irohPrivatePathRemoveFailed"],
  [661, "connectionMethodConfigured"],
  [662, "foregroundTransportSelected"],
]);

const allowedPropertyKeys = new Set([
  "event_code",
  "event_name",
  "outcome",
  "runtime_role",
  "user_usable",
  "duration_ms",
  "correlation_id",
  "detail_a",
  "detail_b",
  "detail_c",
  "failure",
  "transport",
  "path",
  "operation_code",
  "operation",
  "platform",
  "app_version",
  "build_number",
  "bundle_identifier",
  "os_version",
  "device_model",
]);

const outcomes = new Set(["started", "success", "failure", "state"]);
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
const paths = new Set(["unknown", "direct", "relay", "privateNetwork", "loopback"]);

export type MobileNetworkOutcome = {
  readonly timestamp: string;
  readonly eventCode: number;
  readonly eventName: string;
  readonly outcome: "started" | "success" | "failure" | "state";
  readonly runtimeRole: "mobileClient";
  readonly userUsable: boolean;
  readonly durationMs?: number;
  readonly correlationId?: number;
  readonly detailA?: number;
  readonly detailB?: number;
  readonly detailC?: number;
  readonly failure?: string;
  readonly transport?: string;
  readonly path?: string;
  readonly operationCode?: number;
  readonly operation?: string;
  readonly platform?: "ios";
  readonly appVersion?: string;
  readonly buildNumber?: string;
  readonly bundleIdentifier?: string;
  readonly osVersion?: string;
  readonly deviceModel?: string;
};

export function parseMobileNetworkOutcome(candidate: unknown): MobileNetworkOutcome | null {
  if (!isRecord(candidate) || candidate.event !== EVENT_NAME || !isRecord(candidate.properties)) {
    return null;
  }
  const properties = candidate.properties;
  if (Object.keys(properties).some((key) => !allowedPropertyKeys.has(key))) return null;

  const eventCode = unsignedInteger(properties.event_code);
  if (eventCode === null || eventNames.get(eventCode) !== properties.event_name) return null;
  if (typeof properties.outcome !== "string" || !outcomes.has(properties.outcome)) return null;
  if (properties.runtime_role !== RUNTIME_ROLE || typeof properties.user_usable !== "boolean") {
    return null;
  }
  if (
    typeof candidate.timestamp !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(candidate.timestamp) ||
    !Number.isFinite(Date.parse(candidate.timestamp))
  ) {
    return null;
  }

  const operationCode = optionalUnsignedInteger(properties.operation_code);
  if (operationCode === false) return null;
  const operation = optionalMachineString(properties.operation);
  if (operation === false) return null;
  if (eventCode === 65) {
    if (typeof operationCode !== "number" || typeof operation !== "string") return null;
    const canonicalOperation = operationNames.get(operationCode);
    if (canonicalOperation !== undefined && canonicalOperation !== operation) return null;
  } else if (operationCode !== undefined || operation !== undefined) {
    return null;
  }

  const durationMs = optionalUnsignedInteger(properties.duration_ms);
  const correlationId = optionalUnsignedInteger(properties.correlation_id);
  const detailA = optionalSafeInteger(properties.detail_a);
  const detailB = optionalSafeInteger(properties.detail_b);
  const detailC = optionalSafeInteger(properties.detail_c);
  if ([durationMs, correlationId, detailA, detailB, detailC].includes(false)) return null;

  const failure = optionalSetValue(properties.failure, failures);
  const transport = optionalSetValue(properties.transport, transports);
  const path = optionalSetValue(properties.path, paths);
  if ([failure, transport, path].includes(false)) return null;

  const platform = optionalExact(properties.platform, "ios");
  const appVersion = optionalMachineString(properties.app_version);
  const buildNumber = optionalMachineString(properties.build_number);
  const bundleIdentifier = optionalMachineString(properties.bundle_identifier);
  const osVersion = optionalMachineString(properties.os_version);
  const deviceModel = optionalMachineString(properties.device_model, true);
  if ([platform, appVersion, buildNumber, bundleIdentifier, osVersion, deviceModel].includes(false)) {
    return null;
  }

  return {
    timestamp: candidate.timestamp,
    eventCode,
    eventName: properties.event_name as string,
    outcome: properties.outcome as MobileNetworkOutcome["outcome"],
    runtimeRole: RUNTIME_ROLE,
    userUsable: properties.user_usable,
    ...(typeof durationMs === "number" ? { durationMs } : {}),
    ...(typeof correlationId === "number" ? { correlationId } : {}),
    ...(typeof detailA === "number" ? { detailA } : {}),
    ...(typeof detailB === "number" ? { detailB } : {}),
    ...(typeof detailC === "number" ? { detailC } : {}),
    ...(typeof failure === "string" ? { failure } : {}),
    ...(typeof transport === "string" ? { transport } : {}),
    ...(typeof path === "string" ? { path } : {}),
    ...(typeof operationCode === "number" ? { operationCode } : {}),
    ...(typeof operationCode === "number"
      ? { operation: operationNames.get(operationCode) ?? `diagnosticAppEvent${operationCode}` }
      : {}),
    ...(platform === "ios" ? { platform } : {}),
    ...(typeof appVersion === "string" ? { appVersion } : {}),
    ...(typeof buildNumber === "string" ? { buildNumber } : {}),
    ...(typeof bundleIdentifier === "string" ? { bundleIdentifier } : {}),
    ...(typeof osVersion === "string" ? { osVersion } : {}),
    ...(typeof deviceModel === "string" ? { deviceModel } : {}),
  };
}

/** Emits one fixed-name span per outcome into the configured Axiom OTLP exporter. */
export async function emitMobileNetworkOutcomes(
  userId: string,
  batch: readonly MobileNetworkOutcome[],
): Promise<void> {
  await Promise.all(batch.map((outcome) => withSpan(
    "cmux-mobile-network",
    "cmux.mobile.network.outcome",
    {
      "cmux.subsystem": "mobile-network",
      "cmux.runtime": "ios",
      "cmux.user_id": userId,
      "cmux.mobile.event_code": outcome.eventCode,
      "cmux.mobile.event_name": outcome.eventName,
      "cmux.mobile.outcome": outcome.outcome,
      "cmux.mobile.is_failure": outcome.outcome === "failure",
      "cmux.mobile.user_usable": outcome.userUsable,
      "cmux.mobile.occurred_at": outcome.timestamp,
      "cmux.mobile.duration_ms": outcome.durationMs,
      "cmux.mobile.correlation_id": outcome.correlationId,
      "cmux.mobile.detail_a": outcome.detailA,
      "cmux.mobile.detail_b": outcome.detailB,
      "cmux.mobile.detail_c": outcome.detailC,
      "cmux.mobile.failure": outcome.failure,
      "cmux.mobile.transport": outcome.transport,
      "cmux.mobile.path": outcome.path,
      "cmux.mobile.operation_code": outcome.operationCode,
      "cmux.mobile.operation": outcome.operation,
      "cmux.mobile.platform": outcome.platform,
      "cmux.mobile.app_version": outcome.appVersion,
      "cmux.mobile.build_number": outcome.buildNumber,
      "cmux.mobile.bundle_identifier": outcome.bundleIdentifier,
      "cmux.mobile.os_version": outcome.osVersion,
      "cmux.mobile.device_model": outcome.deviceModel,
    },
    (span) => {
      if (outcome.outcome === "failure") {
        span.setStatus({ code: SpanStatusCode.ERROR, message: outcome.failure ?? outcome.eventName });
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

function optionalUnsignedInteger(value: unknown): number | undefined | false {
  if (value === undefined) return undefined;
  return unsignedInteger(value) ?? false;
}

function optionalSafeInteger(value: unknown): number | undefined | false {
  if (value === undefined) return undefined;
  return Number.isSafeInteger(value) ? Number(value) : false;
}

function optionalSetValue(
  value: unknown,
  allowed: ReadonlySet<string>,
): string | undefined | false {
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
