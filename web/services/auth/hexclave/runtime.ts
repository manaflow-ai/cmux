import { cloudDb } from "../../../db/client";
import { invalidateNativeAuthCacheForUser } from "../../vms/auth";
import { revokeTeamAccess, revokeTeamMemberAccess } from "../../vms/teamMemberRevocation";
import { deleteIdentitySnapshot } from "../identitySnapshot";
import {
  DEAD_LETTER_RETENTION_MS,
  drainHexclaveInbox,
  PROCESSED_EVENT_RETENTION_MS,
  STUCK_ATTEMPTS,
  type DrainResult,
  type HexclaveInboxStore,
} from "./inbox";
import { createDrizzleHexclaveInboxStore } from "./inboxStore";
import { createDrizzleHexclaveMirrorStore } from "./mirrorStore";
import { createHexclaveServerApi } from "./serverApi";
import type { HexclaveSyncDependencies } from "./sync";

/** Drop every cached view of a user's identity; a failed snapshot delete throws so the event is retried. */
export async function invalidateHexclaveUser(userId: string): Promise<void> {
  invalidateNativeAuthCacheForUser(userId);
  await deleteIdentitySnapshot(userId, undefined, { throwOnError: true });
}

/** Production wiring, or null when Hexclave server credentials are missing. */
export function hexclaveSyncDependencies(config: {
  readonly projectId: string | undefined;
  readonly secretServerKey: string | undefined;
}): HexclaveSyncDependencies | null {
  if (!config.projectId || !config.secretServerKey) return null;
  return {
    // Reads run under a mirror lock: one attempt each, short timeout, no
    // backoff. A failure answers 500 and Svix redelivers later.
    source: createHexclaveServerApi({
      projectId: config.projectId,
      secretServerKey: config.secretServerKey,
      retries: 0,
      timeoutMs: 5_000,
    }),
    store: createDrizzleHexclaveMirrorStore(cloudDb),
    revokeTeamMemberAccess,
    revokeTeamAccess,
    invalidateUser: invalidateHexclaveUser,
  };
}

/** The production inbox. */
export function hexclaveInboxStore(): HexclaveInboxStore {
  return createDrizzleHexclaveInboxStore(cloudDb);
}

/** Entities one after-response drain applies; the cron applies more per run. */
export const WEBHOOK_KICK_ENTITY_LIMIT = 10;
export const CRON_DRAIN_ENTITY_LIMIT = 40;

/** One drain with production wiring, or a skipped result when Hexclave access is not configured. */
export async function drainHexclaveInboxNow(config: {
  readonly projectId: string | undefined;
  readonly secretServerKey: string | undefined;
  readonly entityLimit: number;
}): Promise<DrainResult> {
  const sync = hexclaveSyncDependencies(config);
  if (!sync) return { skipped: true, entities: 0, events: 0, deferredEvents: 0, throttled: false };
  return drainHexclaveInbox({ inbox: hexclaveInboxStore(), sync, entityLimit: config.entityLimit, log: logLine });
}

export type InboxMaintenance = {
  readonly drain: DrainResult;
  readonly stuck: number;
  readonly deadLettered: number;
  /** The stuck or dead-letter count changed to a nonzero value since the last alert. */
  readonly alert: boolean;
  readonly purged: { readonly deadLettered: number; readonly processedEvents: number };
};

/** The cron's run: one drain, health with change-only alerting, and retention purges. */
export async function maintainHexclaveInbox(config: {
  readonly projectId: string | undefined;
  readonly secretServerKey: string | undefined;
  readonly entityLimit: number;
  readonly now?: Date;
}): Promise<InboxMaintenance> {
  const inbox = hexclaveInboxStore();
  const drain = await drainHexclaveInboxNow(config);
  const health = await inbox.health(STUCK_ATTEMPTS);
  const changed = await inbox.recordReportedHealth(health);
  const now = (config.now ?? new Date()).getTime();
  const purged = {
    deadLettered: await inbox.purgeDeadLettered(new Date(now - DEAD_LETTER_RETENTION_MS)),
    processedEvents: await inbox.purgeProcessedEvents(new Date(now - PROCESSED_EVENT_RETENTION_MS)),
  };
  return { drain, ...health, alert: changed && (health.stuck > 0 || health.deadLettered > 0), purged };
}

function logLine(level: "info" | "warn" | "error", message: string, fields: Record<string, unknown>): void {
  const line = JSON.stringify({ message, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.info(line);
}
