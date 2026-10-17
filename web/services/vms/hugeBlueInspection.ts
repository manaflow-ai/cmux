import type { CmuxTuiAttachBundle } from "./drivers/cmuxTuiDaemon";
import type { VmRuntimeEnv } from "./config";

/**
 * Read-only Huge Blue app-server inspection (#21332, design in
 * docs/design/huge-blue-app-server-inspection.md).
 *
 * Inspection answers whether a registered Cloud machine can be observed. It
 * never creates a Run, mints a terminal route token, or returns provider
 * credentials, invitation material, shell commands or route addresses. The
 * mapper below is the only place a probe becomes a state, and it fails
 * closed: missing, malformed or contradictory evidence never reads as
 * `admitted`.
 */
export const HUGE_BLUE_INSPECTION_STATES = ["disabled", "unavailable", "unenrolled", "admitted"] as const;
export type HugeBlueInspectionState = (typeof HUGE_BLUE_INSPECTION_STATES)[number];

export type HugeBlueInspectionReasonCode =
  | "inspection_disabled"
  | "adapter_not_configured"
  | "target_not_running"
  | "probe_failed"
  | "daemon_probe_unreadable"
  | "device_not_enrolled"
  | "trusted_carrier"
  | "device_enrolled";

/** Deployment switch: `enabled` probes, `disabled` is an explicit policy refusal, anything else is unconfigured. */
export const HUGE_BLUE_INSPECTION_ENV = "CMUX_HUGE_BLUE_INSPECTION";

export type HugeBlueInspectionMode = "enabled" | "disabled" | "unconfigured";

export function hugeBlueInspectionMode(env: VmRuntimeEnv = process.env): HugeBlueInspectionMode {
  const value = env[HUGE_BLUE_INSPECTION_ENV]?.trim().toLowerCase();
  if (value === "enabled") return "enabled";
  if (value === "disabled") return "disabled";
  return "unconfigured";
}

/** What the server observed about the target, before it becomes a state. */
export type HugeBlueInspectionObservation =
  | { readonly kind: "disabled" }
  | { readonly kind: "unconfigured" }
  | { readonly kind: "not_running" }
  | { readonly kind: "probe_failed" }
  | { readonly kind: "probed"; readonly bundle: CmuxTuiAttachBundle; readonly deviceFingerprintGiven: boolean };

export type HugeBlueInspectionCapabilities = {
  readonly readOnlyInspection: true;
  readonly daemonProtocol: number | null;
  readonly trustedCarrier: boolean;
  readonly enrolled: boolean;
};

export type HugeBlueInspectionView = {
  /** The caller's registered machine id, never a provider route. */
  readonly host: string;
  /** The cmux-tui session the machine's daemon owns. */
  readonly session: string;
  readonly state: HugeBlueInspectionState;
  readonly reasonCode: HugeBlueInspectionReasonCode;
  readonly retryable: boolean;
  readonly checkedAt: string;
  readonly capabilities: HugeBlueInspectionCapabilities;
};

type StateVerdict = Pick<HugeBlueInspectionView, "state" | "reasonCode" | "retryable">;

const NO_EVIDENCE: HugeBlueInspectionCapabilities = {
  readOnlyInspection: true,
  daemonProtocol: null,
  trustedCarrier: false,
  enrolled: false,
};

function validProtocol(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
}

function probedVerdict(
  bundle: CmuxTuiAttachBundle,
  deviceFingerprintGiven: boolean,
): { readonly verdict: StateVerdict; readonly capabilities: HugeBlueInspectionCapabilities } {
  const daemonProtocol = validProtocol(bundle.daemonBuild?.remoteProtocol);
  // Enrollment only counts when the caller named the device it was checked for.
  const enrolled = deviceFingerprintGiven && bundle.enrolled === true;
  const trustedCarrier = bundle.trustedCarrier === true;
  if (daemonProtocol === null) {
    // No readable daemon build means nothing else in the bundle is trusted.
    return {
      verdict: { state: "unavailable", reasonCode: "daemon_probe_unreadable", retryable: true },
      capabilities: NO_EVIDENCE,
    };
  }
  const capabilities: HugeBlueInspectionCapabilities = { readOnlyInspection: true, daemonProtocol, trustedCarrier, enrolled };
  if (trustedCarrier) return { verdict: { state: "admitted", reasonCode: "trusted_carrier", retryable: false }, capabilities };
  if (enrolled) return { verdict: { state: "admitted", reasonCode: "device_enrolled", retryable: false }, capabilities };
  return { verdict: { state: "unenrolled", reasonCode: "device_not_enrolled", retryable: false }, capabilities };
}

/** Maps one observation to the typed, redacted inspection view. */
export function hugeBlueInspectionView(input: {
  readonly host: string;
  readonly session: string;
  readonly observation: HugeBlueInspectionObservation;
  readonly now: Date;
}): HugeBlueInspectionView {
  const base = { host: input.host, session: input.session, checkedAt: input.now.toISOString() };
  const observation = input.observation;
  switch (observation.kind) {
    case "disabled":
      return { ...base, state: "disabled", reasonCode: "inspection_disabled", retryable: false, capabilities: NO_EVIDENCE };
    case "unconfigured":
      return { ...base, state: "unavailable", reasonCode: "adapter_not_configured", retryable: false, capabilities: NO_EVIDENCE };
    case "not_running":
      return { ...base, state: "unavailable", reasonCode: "target_not_running", retryable: true, capabilities: NO_EVIDENCE };
    case "probe_failed":
      return { ...base, state: "unavailable", reasonCode: "probe_failed", retryable: true, capabilities: NO_EVIDENCE };
    case "probed": {
      const { verdict, capabilities } = probedVerdict(observation.bundle, observation.deviceFingerprintGiven);
      return { ...base, ...verdict, capabilities };
    }
  }
}
