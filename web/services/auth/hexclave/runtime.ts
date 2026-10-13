import { cloudDb } from "../../../db/client";
import { invalidateNativeAuthCacheForUser } from "../../vms/auth";
import { revokeTeamAccess, revokeTeamMemberAccess } from "../../vms/teamMemberRevocation";
import { deleteIdentitySnapshot } from "../identitySnapshot";
import { drainHexclaveInbox, STUCK_ATTEMPTS, type DrainResult, type HexclaveInboxStore } from "./inbox";
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
}): Promise<DrainResult & { readonly stuck: number }> {
  const sync = hexclaveSyncDependencies(config);
  const inbox = hexclaveInboxStore();
  if (!sync) return { skipped: true, entities: 0, events: 0, deferredEvents: 0, throttled: false, stuck: 0 };
  const result = await drainHexclaveInbox({
    inbox,
    sync,
    entityLimit: config.entityLimit,
    log: (level, message, fields) => {
      const line = JSON.stringify({ message, ...fields });
      if (level === "error") console.error(line);
      else if (level === "warn") console.warn(line);
      else console.info(line);
    },
  });
  return { ...result, stuck: await inbox.countStuck(STUCK_ATTEMPTS) };
}
