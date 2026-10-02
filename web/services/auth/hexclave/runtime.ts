import { cloudDb } from "../../../db/client";
import { invalidateNativeAuthCacheForUser } from "../../vms/auth";
import { revokeTeamAccess, revokeTeamMemberAccess } from "../../vms/teamMemberRevocation";
import { deleteIdentitySnapshot } from "../identitySnapshot";
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
