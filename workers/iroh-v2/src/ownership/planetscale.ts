import { and, eq, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import type { DeviceDescriptor } from "../contracts/common";
import { canonicalJSON, hash, identityKey } from "../crypto";
import { OperationError } from "../errors";
import { endpointOwners, ownerBudgets } from "./schema";

export interface EndpointOwnership {
  /** Called only after successful device proof and a matching pending challenge. */
  reserve(device: DeviceDescriptor, now: number): Promise<void>;
}

/** No directory read or credential renewal traverses this adapter. The URL is
 * normally the generated Hyperdrive URL for the isolated IROH database. */
export class PlanetScaleOwnership implements EndpointOwnership {
  constructor(private readonly databaseURL: string, private readonly environment: string, private readonly projectId: string) {
    const url = new URL(databaseURL);
    if (url.protocol !== "postgresql:" && url.protocol !== "postgres:") throw new Error("PlanetScale ownership requires PostgreSQL");
    if (!url.hostname) throw new Error("PlanetScale ownership requires a database host");
  }

  async reserve(device: DeviceDescriptor, now: number): Promise<void> {
    const identity = device.identity;
    if (identity.environment !== this.environment || identity.projectId !== this.projectId) throw new OperationError("environment_mismatch", 403);
    const identityHash = await identityKey(device);
    const userScopeHash = await hash(canonicalJSON({ environment: identity.environment, projectId: identity.projectId, userId: identity.userId }));
    const connection = postgres(this.databaseURL, {
      max: 1, prepare: false, connect_timeout: 5, idle_timeout: 1,
      connection: { statement_timeout: 5000 },
    });
    const db = drizzle(connection);
    try {
      await db.transaction(async tx => {
        await tx.insert(ownerBudgets).values({ userScopeHash, ownerCount: 0 }).onConflictDoNothing();
        const [budget] = await tx.select().from(ownerBudgets).where(eq(ownerBudgets.userScopeHash, userScopeHash)).for("update");
        if (!budget) throw new Error("Missing ownership budget");
        const [existing] = await tx.select().from(endpointOwners).where(eq(endpointOwners.endpointId, device.endpointId));
        if (existing) {
          if (existing.identityHash !== identityHash) throw new OperationError("endpoint_already_owned", 409);
          return;
        }
        if (budget.ownerCount >= 4096) throw new OperationError("device_limit", 429);
        const inserted = await tx.insert(endpointOwners).values({
          endpointId: device.endpointId, identityHash, environment: identity.environment,
          projectId: identity.projectId, teamId: identity.teamId, userId: identity.userId,
          identityJson: canonicalJSON(identity), createdAt: now,
        }).onConflictDoNothing().returning({ endpointId: endpointOwners.endpointId });
        if (inserted.length === 0) {
          // Another user's transaction may have won while this transaction held
          // only our user's budget lock. The unique endpoint key decides ownership.
          const [winner] = await tx.select().from(endpointOwners).where(and(eq(endpointOwners.endpointId, device.endpointId), eq(endpointOwners.identityHash, identityHash)));
          if (!winner) throw new OperationError("endpoint_already_owned", 409);
          return;
        }
        await tx.update(ownerBudgets).set({ ownerCount: sql`${ownerBudgets.ownerCount} + 1` }).where(eq(ownerBudgets.userScopeHash, userScopeHash));
      });
    } catch (error) {
      if (error instanceof OperationError) throw error;
      throw new OperationError("storage_unavailable", 503, true, 2000);
    } finally { await connection.end({ timeout: 1 }); }
  }
}
