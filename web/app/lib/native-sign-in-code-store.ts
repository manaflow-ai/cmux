import { and, eq, gt, lt } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { nativeSignInCodes } from "../../db/schema";
import type { NativeSignInCodeRecord, NativeSignInCodeStore } from "./native-sign-in-codes";

/**
 * The Postgres store for native sign-in codes. `consume` is one
 * `DELETE ... RETURNING`, so two concurrent redemptions cannot both win.
 */
export function postgresNativeSignInCodeStore(getDb: typeof cloudDb = cloudDb): NativeSignInCodeStore {
  return {
    insert: async (record) => {
      const db = getDb();
      // Expired rows are never redeemable; drop them as new ones arrive.
      await db.delete(nativeSignInCodes).where(lt(nativeSignInCodes.expiresAt, new Date()));
      await db.insert(nativeSignInCodes).values({
        codeHash: record.codeHash,
        codeChallenge: record.codeChallenge,
        scheme: record.scheme,
        userId: record.userId,
        expiresAt: record.expiresAt,
      });
    },
    consume: async (codeHash, now): Promise<NativeSignInCodeRecord | null> => {
      const [row] = await getDb()
        .delete(nativeSignInCodes)
        .where(and(eq(nativeSignInCodes.codeHash, codeHash), gt(nativeSignInCodes.expiresAt, now)))
        .returning();
      if (!row) return null;
      return {
        codeHash: row.codeHash,
        codeChallenge: row.codeChallenge,
        scheme: row.scheme,
        userId: row.userId,
        expiresAt: row.expiresAt,
      };
    },
  };
}
