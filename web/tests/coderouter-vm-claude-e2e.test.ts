import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { mintVmModelPlaneEnv } from "../services/coderouter/vmModelPlane";
import { createClaudeMessagesProxy } from "../services/coderouter/claudeProxy";
import {
  authenticateRouteToken,
  issueRouteToken,
  markAccountCooldown,
  revokeRouteTokensForTeam,
  selectAccountForSession,
} from "../services/coderouter/repository";

// The whole Cloud VM Claude loop, minus only the pieces that need external
// services: a real route token is minted the way POST /api/vm does it, the
// real baked-image agent-config.sh materializes the machine env from it, and
// the /v1/messages plane authenticates that env against the real database.
// Only KMS (credential decryption) and api.anthropic.com are stubbed.
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const TEAM = "team-vm-claude-e2e";
const agentConfigPath = path.join(
  import.meta.dirname,
  "../services/vms/images/blaxel/agent-config.sh",
);
let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 4 });
});

async function deleteTeamRows(): Promise<void> {
  if (!sql) return;
  await sql`delete from coderouter_route_tokens where team_id = ${TEAM}`;
  await sql`delete from coderouter_accounts where team_id = ${TEAM}`;
}

afterAll(async () => {
  try {
    await deleteTeamRows();
  } finally {
    try {
      await closeCloudDbForTests();
    } finally {
      await sql?.end({ timeout: 5 });
    }
  }
});

beforeEach(deleteTeamRows);

/** What the machine's shells see after sourcing the baked agent-config.sh. */
function materializeMachineEnv(
  mintedEnv: Record<string, string>,
): { anthropicBaseUrl: string; anthropicAuthToken: string } {
  const home = mkdtempSync(path.join(tmpdir(), "cmux-vm-claude-e2e-"));
  try {
    const result = spawnSync(
      "bash",
      [
        "-c",
        `. ${agentConfigPath} && printf '%s\\n%s\\n' "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN"`,
      ],
      {
        // A developer's own Claude Code env must not leak in: the generator
        // is set-if-unset, so clear both so the derivation path is exercised.
        env: {
          ...process.env,
          ANTHROPIC_BASE_URL: "",
          ANTHROPIC_AUTH_TOKEN: "",
          ...mintedEnv,
          HOME: home,
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(`agent-config.sh exited ${result.status}: ${result.stderr}`);
    }
    const [anthropicBaseUrl, anthropicAuthToken] = result.stdout.split("\n");
    return {
      anthropicBaseUrl: anthropicBaseUrl ?? "",
      anthropicAuthToken: anthropicAuthToken ?? "",
    };
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

describe("cloud VM claude model plane, end to end", () => {
  dbTest("a machine minted at create reaches Anthropic through the plane", async () => {
    // 1. Control plane: POST /api/vm mints this exact env for the machine.
    const mintedEnv = await mintVmModelPlaneEnv(
      {
        teamId: TEAM,
        stackUserId: "stack-user-e2e",
        requestUrl: "https://cmux.test/api/vm",
      },
      {
        issueToken: issueRouteToken,
        entitlement: async () => {
          throw new Error("entitlement must not be consulted when ungated");
        },
        hostedProRequired: () => false,
        enabled: () => true,
      },
    );
    expect(mintedEnv).not.toBeNull();
    expect(mintedEnv?.OPENAI_BASE_URL).toBe("https://cmux.test/v1");
    expect(mintedEnv?.OPENAI_API_KEY?.startsWith("crt_")).toBe(true);

    // 2. Machine: the baked generator derives Claude Code's env from it.
    const machine = materializeMachineEnv(mintedEnv!);
    expect(machine.anthropicBaseUrl).toBe("https://cmux.test");
    expect(machine.anthropicAuthToken).toBe(mintedEnv!.OPENAI_API_KEY);

    // 3. Data plane: the team has one Claude Max account in the vault.
    const accountId = randomUUID();
    await sql!`
      insert into coderouter_accounts
        (id, team_id, provider, provider_account_id, label, state)
      values
        (${accountId}, ${TEAM}, 'claude', 'claude-acct', 'person@example.com', 'active')
    `;
    const upstream: { url: string; authorization: string | null; beta: string | null }[] = [];
    const proxy = createClaudeMessagesProxy({
      authenticate: authenticateRouteToken,
      select: selectAccountForSession,
      // KMS boundary: the envelope-encrypted credential is stubbed with the
      // account's decrypted shape.
      credential: async ({ accountId: requested }) => ({
        provider: "claude",
        accessToken: `leased-${requested}`,
        refreshToken: "refresh",
        accountId: "claude-acct",
        email: "person@example.com",
        expiresAt: Date.now() + 60_000,
      }),
      cooldown: markAccountCooldown,
    });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (url: string | URL | Request, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      upstream.push({
        url: String(url),
        authorization: headers.get("authorization"),
        beta: headers.get("anthropic-beta"),
      });
      return Response.json({ type: "message" });
    }) as typeof fetch;
    try {
      // 4. Claude Code on the machine sends its bearer straight from the env.
      const respond = () =>
        proxy(
          new Request(`${machine.anthropicBaseUrl}/v1/messages`, {
            method: "POST",
            headers: {
              authorization: `Bearer ${machine.anthropicAuthToken}`,
              "content-type": "application/json",
              "anthropic-version": "2023-06-01",
              "user-agent": "claude-cli/2.1.0 (external)",
            },
            body: JSON.stringify({
              model: "claude-sonnet-5",
              max_tokens: 32,
              messages: [{ role: "user", content: "hello" }],
              metadata: { user_id: "user_e2e_session_1" },
            }),
          }),
        );
      const response = await respond();
      expect(response.status).toBe(200);
      expect(upstream).toHaveLength(1);
      expect(upstream[0]?.url).toBe("https://api.anthropic.com/v1/messages");
      expect(upstream[0]?.authorization).toBe(`Bearer leased-${accountId}`);
      expect(upstream[0]?.beta).toBe("oauth-2025-04-20");

      // 5. Fail closed: revoking the team's tokens cuts the machine off.
      await revokeRouteTokensForTeam(TEAM);
      const revoked = await respond();
      expect(revoked.status).toBe(401);
      expect(upstream).toHaveLength(1);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
