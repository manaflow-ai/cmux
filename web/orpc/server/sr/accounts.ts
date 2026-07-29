import { ORPCError } from "@orpc/server";
import { and, eq } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { srVaultEntries } from "../../../db/schema";
import { resolveBillingTeam } from "../../../services/billing/teamResolution";
import { isVaultConfigured, seal } from "../../../services/subrouter/vaultCrypto";
import { os, requireAuth, type AuthedUser } from "../base";
import {
  srAccountsListOutputSchema,
  srAccountsPushInputSchema,
  srAccountsPushOutputSchema,
} from "./schemas";

// requireTeam resolves the Stack team that owns the vault entries. Team
// membership is the authorization boundary: there is no separate ACL, so
// sharing an account with the team is the same act as uploading it.
async function requireTeam(user: AuthedUser): Promise<string> {
  const team = await resolveBillingTeam(user);
  if (!team) {
    throw new ORPCError("FORBIDDEN", {
      message: "No Stack team resolved for this user; create or select a team first",
    });
  }
  return team.id;
}

function requireVault(): void {
  if (!isVaultConfigured()) {
    // Failing loudly beats storing plaintext credentials by accident.
    throw new ORPCError("INTERNAL_SERVER_ERROR", {
      message: "Subrouter vault is not configured on this deployment",
    });
  }
}

export const srAccountsPushProcedure = os
  .route({
    method: "POST",
    path: "/sr/accounts/push",
    operationId: "sr.accounts.push",
    summary: "Upload Subrouter credentials to the team vault",
    description:
      "Seals one or more provider credentials and stores them for the caller's team. Existing accounts are updated in place rather than duplicated.",
    tags: ["Subrouter"],
    successStatus: 200,
  })
  .input(srAccountsPushInputSchema)
  .output(srAccountsPushOutputSchema)
  .use(requireAuth)
  .handler(async ({ context, input }) => {
    requireVault();
    const teamId = await requireTeam(context.user);
    const db = cloudDb();

    let uploaded = 0;
    let updated = 0;
    for (const account of input.accounts) {
      const sealed = seal(account.credential);
      const existing = await db
        .select({ id: srVaultEntries.id })
        .from(srVaultEntries)
        .where(
          and(
            eq(srVaultEntries.teamId, teamId),
            eq(srVaultEntries.provider, account.provider),
            eq(srVaultEntries.accountLabel, account.accountLabel),
          ),
        )
        .limit(1);

      if (existing.length > 0) {
        await db
          .update(srVaultEntries)
          .set({
            ciphertext: sealed.ciphertext,
            nonce: sealed.nonce,
            keyVersion: sealed.keyVersion,
            updatedAt: new Date(),
          })
          .where(eq(srVaultEntries.id, existing[0]!.id));
        updated += 1;
        continue;
      }

      await db.insert(srVaultEntries).values({
        teamId,
        provider: account.provider,
        accountLabel: account.accountLabel,
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
        keyVersion: sealed.keyVersion,
        createdByUserId: context.user.id ?? "",
      });
      uploaded += 1;
    }

    return { teamId, uploaded, updated };
  });

export const srAccountsListProcedure = os
  .route({
    method: "GET",
    path: "/sr/accounts",
    operationId: "sr.accounts.list",
    summary: "List Subrouter accounts available to the team",
    description:
      "Returns account identities only. Credential material is never returned by this endpoint.",
    tags: ["Subrouter"],
    successStatus: 200,
  })
  .output(srAccountsListOutputSchema)
  .use(requireAuth)
  .handler(async ({ context }) => {
    const teamId = await requireTeam(context.user);
    const rows = await cloudDb()
      .select({
        provider: srVaultEntries.provider,
        accountLabel: srVaultEntries.accountLabel,
        updatedAt: srVaultEntries.updatedAt,
      })
      .from(srVaultEntries)
      .where(eq(srVaultEntries.teamId, teamId));

    return {
      teamId,
      accounts: rows.map((row) => ({
        // The column is a plain text column; the schema enum narrows it back.
        provider: row.provider as "codex" | "claude" | "gemini" | "apikey",
        accountLabel: row.accountLabel,
        updatedAt: row.updatedAt.toISOString(),
      })),
    };
  });
