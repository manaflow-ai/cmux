/**
 * Build the redacted lifecycle packet emitted by the Cloud dogfood journey.
 *
 * A missing observation is deliberately `unverified`; it is never inferred
 * from a successful neighboring step.  The packet is evidence for a staging
 * run, not a provider attestation.
 */
export const LIFECYCLE_RECEIPT_SCHEMA = "cmux.cloud.lifecycle-receipt/v1";
export const LIFECYCLE_STATES = Object.freeze([
  "accepted",
  "running",
  "completed",
  "failed",
  "cancelled",
  "unverified",
]);

const SHA = /^[0-9a-f]{40,64}$/i;

function state(value) {
  return LIFECYCLE_STATES.includes(value) ? value : "unverified";
}

function observed(ok, reason, evidence = {}) {
  return ok === true
    ? { state: "completed", ...evidence }
    : { state: "unverified", reason };
}

function observedState(value, reason, evidence = {}) {
  return LIFECYCLE_STATES.includes(value) ? { state: value, ...evidence } : observed(value === true, reason, evidence);
}

function source(sha) {
  return SHA.test(sha ?? "") ? { state: "completed", sha } : { state: "unverified", reason: "exact source SHA was not supplied" };
}

function operation(operation) {
  const states = Array.isArray(operation?.states) ? operation.states : [];
  return {
    name: typeof operation?.name === "string" ? operation.name : "unknown",
    states: states.map((entry) => ({
      state: state(entry?.state),
      ...(Number.isFinite(entry?.atMs) ? { atMs: Math.max(0, Math.round(entry.atMs)) } : {}),
    })),
  };
}

export function finalLifecycleState({ ok, cancelled = false } = {}) {
  if (cancelled === true) return "cancelled";
  if (ok === true) return "completed";
  if (ok === false) return "failed";
  return "unverified";
}

/**
 * Build one packet with stable fields for every provider/control-plane slice.
 * Values that the journey does not exercise are explicit `unverified` rows.
 */
export function buildLifecycleReceipt(input = {}) {
  const machineId = typeof input.machineId === "string" ? input.machineId : undefined;
  const providerName = typeof input.provider === "string" ? input.provider : undefined;
  const imageVersion = typeof input.imageVersion === "string" ? input.imageVersion : undefined;
  const transportPath = typeof input.transportPath === "string" ? input.transportPath : undefined;

  return {
    schema: LIFECYCLE_RECEIPT_SCHEMA,
    state: state(input.state ?? finalLifecycleState(input)),
    source: source(input.sourceSha),
    image: imageVersion
      ? { state: "completed", version: imageVersion }
      : { state: "unverified", reason: "image version was not returned by the create response" },
    provider: providerName
      ? { state: "completed", name: providerName }
      : { state: "unverified", reason: "provider was not returned by the create response" },
    machine: machineId
      ? { state: "completed", id: machineId }
      : { state: "unverified", reason: "machine identity was not returned" },
    lease: observedState(input.leaseState, "the journey does not expose a provider lease identity"),
    attach: observedState(input.attachState, "attach did not complete"),
    network: observedState(input.networkState, "private reachability was not observed", {
      ...(transportPath ? { transportPath } : {}),
    }),
    forkSnapshot: observedState(input.forkSnapshotState, "the journey does not fork or snapshot a machine"),
    cleanup: observedState(input.cleanupState, "cleanup has not produced a terminal observation"),
    quota: observedState(input.quotaState, "the journey does not query the provider or plan quota"),
    terminal: observedState(input.terminalState, "terminal continuity was not observed"),
    operations: Array.isArray(input.operations) ? input.operations.map(operation) : [],
  };
}
