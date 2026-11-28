import { and, eq, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { deviceAppInstances, devices } from "../../db/schema";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";

export type DeviceRegistryWithdrawalResult =
  | { readonly kind: "withdrawn" }
  | { readonly kind: "not_found" }
  | { readonly kind: "not_owned" };

/** Clear one owned app-instance route set without touching sibling tags. */
export function withdrawDeviceInstance(input: {
  readonly deviceUuid: string;
  readonly tag: string;
  readonly teamId: string;
  readonly userId: string;
}): Effect.Effect<DeviceRegistryWithdrawalResult, AccountDeletionMutationBlockedError | Error> {
  return Effect.tryPromise({
    try: async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        await assertAccountDeletionUserMutationAllowed(tx, input.userId);
        // Serialize with registration updates for this team so an in-flight
        // re-registration cannot restore routes after the withdrawal commits.
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.teamId}, 7))`);
        const [device] = await tx
          .select({ id: devices.id })
          .from(devices)
          .where(and(
            eq(devices.teamId, input.teamId),
            eq(devices.deviceUuid, input.deviceUuid),
            eq(devices.userId, input.userId),
          ))
          .limit(1);
        if (!device) return { kind: "not_owned" as const };
        const updated = await tx
          .update(deviceAppInstances)
          .set({ routes: [] })
          .where(and(
            eq(deviceAppInstances.deviceId, device.id),
            eq(deviceAppInstances.teamId, input.teamId),
            eq(deviceAppInstances.tag, input.tag),
          ))
          .returning({ id: deviceAppInstances.id });
        return updated.length > 0
          ? { kind: "withdrawn" as const }
          : { kind: "not_found" as const };
      });
    },
    catch: (error) => error instanceof AccountDeletionMutationBlockedError
      ? error
      : new Error("device registry withdrawal failed", { cause: error }),
  });
}
