import { and, eq, isNull } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { mcpOauthClients, mcpOauthGrants, mcpOauthTokens } from "../../db/schema";
import { MCP_SCOPES, type McpOauthGrant, type McpOauthStore, type McpOauthTokenKind, type McpScope } from "./oauth";

function scopesFrom(value: unknown): McpScope[] {
  return Array.isArray(value)
    ? MCP_SCOPES.filter((scope) => value.includes(scope))
    : [];
}

function grantFrom(row: typeof mcpOauthGrants.$inferSelect): McpOauthGrant {
  return {
    id: row.id,
    clientId: row.clientId,
    clientName: row.clientName,
    stackUserId: row.stackUserId,
    teamId: row.teamId,
    scopes: scopesFrom(row.scopes),
    revokedAt: row.revokedAt,
  };
}

/** The Postgres-backed store the OAuth routes and `/api/mcp` share. */
export function mcpOauthDbStore(): McpOauthStore {
  return {
    insertClient: async (client) => {
      await cloudDb().insert(mcpOauthClients).values({
        clientId: client.clientId,
        clientName: client.clientName,
        redirectUris: [...client.redirectUris],
      });
    },
    findClient: async (clientId) => {
      const [row] = await cloudDb().select().from(mcpOauthClients).where(eq(mcpOauthClients.clientId, clientId)).limit(1);
      if (!row) return null;
      return {
        clientId: row.clientId,
        clientName: row.clientName,
        redirectUris: Array.isArray(row.redirectUris) ? row.redirectUris.filter((uri): uri is string => typeof uri === "string") : [],
      };
    },
    insertGrant: async (grant) => {
      const [row] = await cloudDb().insert(mcpOauthGrants).values({
        clientId: grant.clientId,
        clientName: grant.clientName,
        stackUserId: grant.stackUserId,
        teamId: grant.teamId,
        scopes: [...grant.scopes],
      }).returning();
      return grantFrom(row!);
    },
    findGrant: async (grantId) => {
      const [row] = await cloudDb().select().from(mcpOauthGrants).where(eq(mcpOauthGrants.id, grantId)).limit(1);
      return row ? grantFrom(row) : null;
    },
    revokeGrant: async (grantId, at) => {
      await cloudDb().update(mcpOauthGrants)
        .set({ revokedAt: at })
        .where(and(eq(mcpOauthGrants.id, grantId), isNull(mcpOauthGrants.revokedAt)));
    },
    touchGrant: async (grantId, at) => {
      await cloudDb().update(mcpOauthGrants).set({ lastUsedAt: at }).where(eq(mcpOauthGrants.id, grantId));
    },
    readGrantSettings: async (grantId) => {
      const [row] = await cloudDb().select({ settings: mcpOauthGrants.settings })
        .from(mcpOauthGrants).where(eq(mcpOauthGrants.id, grantId)).limit(1);
      const settings = row?.settings;
      return settings && typeof settings === "object" && !Array.isArray(settings) ? settings : {};
    },
    writeGrantSettings: async (grantId, settings) => {
      await cloudDb().update(mcpOauthGrants).set({ settings }).where(eq(mcpOauthGrants.id, grantId));
    },
    insertToken: async (token) => {
      await cloudDb().insert(mcpOauthTokens).values({
        tokenHash: token.tokenHash,
        grantId: token.grantId,
        kind: token.kind,
        redirectUri: token.redirectUri,
        codeChallenge: token.codeChallenge,
        expiresAt: token.expiresAt,
      });
    },
    findToken: async (tokenHash) => {
      const [row] = await cloudDb().select().from(mcpOauthTokens).where(eq(mcpOauthTokens.tokenHash, tokenHash)).limit(1);
      if (!row) return null;
      return {
        tokenHash: row.tokenHash,
        grantId: row.grantId,
        kind: row.kind as McpOauthTokenKind,
        redirectUri: row.redirectUri,
        codeChallenge: row.codeChallenge,
        expiresAt: row.expiresAt,
        consumedAt: row.consumedAt,
      };
    },
    consumeToken: async (tokenHash, at) => {
      const updated = await cloudDb().update(mcpOauthTokens)
        .set({ consumedAt: at })
        .where(and(eq(mcpOauthTokens.tokenHash, tokenHash), isNull(mcpOauthTokens.consumedAt)))
        .returning({ tokenHash: mcpOauthTokens.tokenHash });
      return updated.length === 1;
    },
  };
}
