// Cloud VM product analytics: the usage ledger mirrored to PostHog.
//
// Every machine lifecycle fact (created, destroyed, attached, exec, fork,
// resume, snapshot, port opened, base opened) is already written once to the
// `cloud_vm_usage_events` ledger by the workflows, whatever path produced it
// (a route, the status-reconcile cron, account deletion). That ledger write is
// the single choke point, so this module decorates the repository and emits
// one PostHog event per allowlisted ledger row, keyed by the Stack user id
// with the billing team as the `stack_team` group and the plan on the person.
//
// Failures are deliberately NOT mirrored here: `cloud_vm_request` and
// `cloud_vm_provision` (services/vms/observability.ts) already carry every
// failure with its error code, and they feed the alerts.
//
// The ledger `metadata` column is free-form JSON, so each event forwards only
// an allowlisted, typed subset of it.
import * as Effect from "effect/Effect";

import {
  captureServerEvent,
  type ServerEventDependencies,
  type ServerEventInput,
  type ServerEventScalar,
} from "../analytics/serverEvents";
import type { VmRepositoryShape, VmUsageEventInput } from "./repository";

export const VM_PRODUCT_ANALYTICS_SCHEMA_VERSION = 1;

/** Ledger event type to PostHog event name. Anything else stays out of PostHog. */
export const VM_LEDGER_TO_POSTHOG_EVENT = {
  "vm.created": "cloud_vm_created",
  "vm.destroyed": "cloud_vm_destroyed",
  "vm.attach": "cloud_vm_attached",
  "vm.exec": "cloud_vm_exec",
  "vm.forked": "cloud_vm_forked",
  "vm.resumed": "cloud_vm_resumed",
  "vm.snapshot.created": "cloud_vm_snapshot_created",
  "vm.open_port": "cloud_vm_port_opened",
  "vm.base.opened": "cloud_vm_base_opened",
  "vm.base.reset": "cloud_vm_base_reset",
} as const satisfies Record<string, string>;

export type VmLedgerEventType = keyof typeof VM_LEDGER_TO_POSTHOG_EVENT;
export type VmProductEventName = (typeof VM_LEDGER_TO_POSTHOG_EVENT)[VmLedgerEventType];

export const VM_PRODUCT_EVENT_NAMES: readonly VmProductEventName[] = Object.values(VM_LEDGER_TO_POSTHOG_EVENT);

/**
 * Why a machine row became destroyed. `destroyVm` stamps the caller's reason
 * into the ledger metadata (`source`); the reconcile cron and base reset
 * stamp theirs at their own write sites.
 */
export const VM_DESTROY_SOURCES = [
  "user_request",
  "account_deletion",
  "provider_status_cron",
  "provider_status_refresh",
  "base_open_provider_missing",
] as const;
export type VmDestroySource = (typeof VM_DESTROY_SOURCES)[number];

type MetadataPicker = (metadata: Record<string, unknown>) => Record<string, ServerEventScalar | null | undefined>;

/**
 * Per-event metadata allowlist. Keys are renamed to snake_case PostHog
 * properties; values are type-checked so a stray object or secret in the
 * ledger metadata can never reach PostHog.
 */
const METADATA_PICKERS: Record<VmLedgerEventType, MetadataPicker> = {
  "vm.created": (m) => ({
    origin: enumValue(m.origin, ["create", "restore", "fork", "base"]) ?? "create",
    image_version: str(m.imageVersion),
    image_size: str(m.imageSize),
    memory_mb: int(m.memoryMb),
    persistent_home: bool(m.persistentHome),
    per_machine_home: bool(m.perMachineHome),
    idempotency_key_set: bool(m.idempotencyKeySet),
  }),
  "vm.destroyed": (m) => ({
    reason: enumValue(m.source, VM_DESTROY_SOURCES) ?? "unknown",
    home_volume_deleted: bool(m.homeVolumeDeleted),
  }),
  "vm.attach": (m) => ({
    transport: str(m.transport) ?? "unknown",
    invited: bool(m.invited),
  }),
  "vm.exec": (m) => ({
    exit_code: int(m.exitCode),
    command_length: int(m.commandLength),
  }),
  "vm.forked": (m) => ({
    native: bool(m.native),
    idempotency_key_set: bool(m.idempotencyKeySet),
  }),
  "vm.resumed": (m) => ({
    source: str(m.source) ?? "unknown",
  }),
  "vm.snapshot.created": (m) => ({
    named: bool(m.named),
  }),
  "vm.open_port": (m) => ({
    port: int(m.port),
  }),
  "vm.base.opened": (m) => ({
    generation: int(m.generation),
  }),
  "vm.base.reset": (m) => ({
    generation: int(m.generation),
  }),
};

/** Ledger rows whose dedupe key is the machine itself: emitted at most once per machine. */
const NATURAL_INSERT_IDS: Partial<Record<VmLedgerEventType, true>> = {
  "vm.created": true,
  "vm.destroyed": true,
};

/**
 * Map one ledger row to its PostHog event, or null when the row is not a
 * product event (failures, credit bookkeeping, unknown types).
 */
export function vmProductEventFromLedger(
  input: VmUsageEventInput,
  now: Date = new Date(),
): ServerEventInput | null {
  if (!isLedgerEventType(input.eventType)) return null;
  const event = VM_LEDGER_TO_POSTHOG_EVENT[input.eventType];
  const metadata = input.metadata ?? {};
  // Account deletion removes the person before provider teardown. Emitting a
  // user-keyed destroy event after that point would recreate the deleted
  // PostHog person, so the ledger row remains the audit record but is not
  // mirrored to product analytics.
  if (input.eventType === "vm.destroyed" && metadata.source === "account_deletion") return null;
  const planId = normalizedPlan(input.billingPlanId);
  const properties: Record<string, ServerEventScalar | null | undefined> = {
    product: "cloud_vm",
    ledger_event: input.eventType,
    vm_id: input.vmId ?? undefined,
    provider: input.provider,
    image_id: input.imageId,
    plan_id: planId,
    billing_team_id: input.billingTeamId ?? undefined,
    schema_version: VM_PRODUCT_ANALYTICS_SCHEMA_VERSION,
    ...METADATA_PICKERS[input.eventType](metadata),
  };
  if (input.eventType === "vm.destroyed" && input.vmCreatedAt) {
    const lifetimeSeconds = Math.round((now.getTime() - input.vmCreatedAt.getTime()) / 1000);
    if (Number.isFinite(lifetimeSeconds) && lifetimeSeconds >= 0) {
      properties.lifetime_seconds = lifetimeSeconds;
    }
  }
  const set: Record<string, ServerEventScalar> = {};
  if (planId) set.billing_plan = planId;
  const setOnce: Record<string, ServerEventScalar> = {};
  if (input.eventType === "vm.created") setOnce.cloud_vm_first_created_at = now.toISOString();
  if (input.eventType === "vm.attach") setOnce.cloud_vm_first_attached_at = now.toISOString();
  return {
    event,
    distinctId: input.userId,
    teamId: input.billingTeamId,
    properties,
    set,
    setOnce,
    insertId: NATURAL_INSERT_IDS[input.eventType] && input.vmId ? `${event}:${input.vmId}` : undefined,
    timestamp: now,
  };
}

export type VmProductCapture = (input: VmUsageEventInput) => void;

/** Default capture: map the ledger row and hand it to the shared sender. */
export function captureVmProductEvent(
  input: VmUsageEventInput,
  dependencies: Partial<ServerEventDependencies> = {},
): void {
  const event = vmProductEventFromLedger(input, dependencies.now?.() ?? new Date());
  if (!event) return;
  void captureServerEvent(event, dependencies);
}

/**
 * Decorate a repository so every successful ledger write also reaches
 * PostHog. Postgres is the source of truth, so capture runs only after the
 * insert succeeds. A capture failure never touches the workflow.
 */
export function withVmProductAnalytics(
  repository: VmRepositoryShape,
  capture: VmProductCapture = captureVmProductEvent,
): VmRepositoryShape {
  const safeCapture = (input: VmUsageEventInput): void => {
    try {
      capture(input);
    } catch (error) {
      console.warn("[analytics] cloud vm product capture failed", {
        event_type: input.eventType,
        error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
      });
    }
  };
  return {
    ...repository,
    recordUsageEvent: (input) =>
      repository.recordUsageEvent(input).pipe(
        Effect.tap(() => Effect.sync(() => safeCapture(input))),
      ),
    recordUsageEvents: (inputs) =>
      repository.recordUsageEvents(inputs).pipe(
        Effect.tap(() => Effect.sync(() => {
          for (const input of inputs) safeCapture(input);
        })),
      ),
  };
}

function isLedgerEventType(value: string): value is VmLedgerEventType {
  return Object.hasOwn(VM_LEDGER_TO_POSTHOG_EVENT, value);
}

function normalizedPlan(planId: string | null | undefined): string | undefined {
  const normalized = planId?.trim().toLowerCase();
  return normalized ? normalized.slice(0, 40) : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value.slice(0, 120) : undefined;
}

function int(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}

function bool(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function enumValue<const Value extends string>(
  value: unknown,
  allowed: readonly Value[],
): Value | undefined {
  return typeof value === "string" && (allowed as readonly string[]).includes(value)
    ? (value as Value)
    : undefined;
}
