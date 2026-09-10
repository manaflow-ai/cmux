import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { listAccounts } from "../services/coderouter/repository";
import {
  authenticateRouteToken,
  bindRouteTokenToVm,
  bindSessionAccount,
  claimAccountForPlacement,
  findSessionAccount,
  issueRouteToken,
  markAccountCooldown,
  revokeRouteTokensForVm,
  selectAccountForSession,
} from "../services/coderouter/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const TEAM = "team-routing-test";
let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 4 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end({ timeout: 5 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate coderouter_session_accounts, coderouter_accounts, coderouter_route_tokens cascade`;
});

async function insertAccounts(count: number): Promise<string[]> {
  if (!sql) throw new Error("no sql client");
  const ids: string[] = [];
  for (let index = 0; index < count; index++) {
    const id = randomUUID();
    ids.push(id);
    await sql`
      insert into coderouter_accounts
        (id, team_id, provider, provider_account_id, label, state)
      values
        (${id}, ${TEAM}, 'codex', ${`provider-${id}`}, ${`Account ${index}`}, 'active')
    `;
  }
  return ids;
}

async function bindingCounts(): Promise<Map<string, number>> {
  if (!sql) throw new Error("no sql client");
  const rows = await sql`
    select account_id, count(*)::int as sessions
    from coderouter_session_accounts
    where team_id = ${TEAM}
    group by account_id
  `;
  return new Map(rows.map((row) => [String(row.account_id), Number(row.sessions)]));
}

describe("coderouter routing db behavior", () => {
  dbTest("sequential new sessions spread evenly across accounts", async () => {
    const accounts = await insertAccounts(4);
    for (let index = 0; index < 8; index++) {
      const placed = await selectAccountForSession({
        teamId: TEAM,
        provider: "codex",
        sessionKey: `session-${index}`,
      });
      expect(placed).not.toBeNull();
      expect(placed?.sticky).toBe(false);
    }
    const counts = await bindingCounts();
    expect(counts.size).toBe(4);
    for (const accountId of accounts) {
      expect(counts.get(accountId)).toBe(2);
    }
  });

  dbTest("concurrent new sessions do not all land on one account", async () => {
    await insertAccounts(4);
    const placements = await Promise.all(
      Array.from({ length: 12 }, (_, index) =>
        selectAccountForSession({
          teamId: TEAM,
          provider: "codex",
          sessionKey: `burst-${index}`,
        })),
    );
    const ids = placements.map((placed) => {
      expect(placed).not.toBeNull();
      return placed?.id ?? "";
    });
    const concentration = new Map<string, number>();
    for (const id of ids) {
      concentration.set(id, (concentration.get(id) ?? 0) + 1);
    }
    // The old read-pick-write race let all 12 pick the same account.
    expect(concentration.size).toBeGreaterThanOrEqual(2);
    const max = Math.max(...concentration.values());
    expect(max).toBeLessThan(12);
  });

  dbTest("a session sticks to its account across requests", async () => {
    await insertAccounts(3);
    const first = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "sticky-session",
    });
    expect(first?.sticky).toBe(false);
    for (let index = 0; index < 5; index++) {
      const again = await selectAccountForSession({
        teamId: TEAM,
        provider: "codex",
        sessionKey: "sticky-session",
      });
      expect(again?.id).toBe(first?.id ?? "");
      expect(again?.sticky).toBe(true);
    }
    // Other sessions in between must not steal the binding.
    await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "other-session",
    });
    const after = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "sticky-session",
    });
    expect(after?.id).toBe(first?.id ?? "");
  });

  dbTest("a session moves once when its account cools down, then resticks", async () => {
    await insertAccounts(3);
    const first = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "moving-session",
    });
    expect(first).not.toBeNull();
    await markAccountCooldown(first?.id ?? "", 60_000);
    const moved = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "moving-session",
    });
    expect(moved).not.toBeNull();
    expect(moved?.id).not.toBe(first?.id ?? "");
    expect(moved?.sticky).toBe(false);
    const stuck = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "moving-session",
    });
    expect(stuck?.id).toBe(moved?.id ?? "");
    expect(stuck?.sticky).toBe(true);
  });

  dbTest("claim skips excluded accounts and drains to null", async () => {
    const accounts = await insertAccounts(2);
    const first = await claimAccountForPlacement(TEAM, "codex", []);
    expect(first).not.toBeNull();
    const second = await claimAccountForPlacement(TEAM, "codex", [first?.id ?? ""]);
    expect(second).not.toBeNull();
    expect(second?.id).not.toBe(first?.id ?? "");
    const drained = await claimAccountForPlacement(TEAM, "codex", accounts);
    expect(drained).toBeNull();
  });

  dbTest("bindings honor exclusion and report null when excluded", async () => {
    await insertAccounts(2);
    const placed = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "excluded-session",
    });
    expect(placed).not.toBeNull();
    const bound = await findSessionAccount(
      TEAM,
      "codex",
      "excluded-session",
      [placed?.id ?? ""],
    );
    expect(bound).toBeNull();
  });

  dbTest("a binding survives its account being mid-refresh", async () => {
    if (!sql) throw new Error("no sql client");
    await insertAccounts(2);
    const first = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "refreshing-session",
    });
    expect(first).not.toBeNull();
    await sql`
      update coderouter_accounts
      set state = 'refreshing',
          refresh_lease_id = ${randomUUID()},
          refresh_lease_expires_at = now() + interval '30 seconds'
      where id = ${first?.id ?? ""}
    `;
    const during = await selectAccountForSession({
      teamId: TEAM,
      provider: "codex",
      sessionKey: "refreshing-session",
    });
    expect(during?.id).toBe(first?.id ?? "");
    expect(during?.sticky).toBe(true);
  });

  dbTest("account listing reports active session counts and cooldowns", async () => {
    if (!sql) throw new Error("no sql client");
    const accounts = await insertAccounts(2);
    await bindSessionAccount(TEAM, "codex", "fresh-session-1", accounts[0] ?? "");
    await bindSessionAccount(TEAM, "codex", "fresh-session-2", accounts[0] ?? "");
    await bindSessionAccount(TEAM, "codex", "stale-session", accounts[1] ?? "");
    await sql`
      update coderouter_session_accounts
      set last_seen_at = now() - interval '7 hours'
      where session_key = 'stale-session'
    `;
    await markAccountCooldown(accounts[1] ?? "", 60_000);
    const listed = await listAccounts(TEAM);
    const byId = new Map(listed.map((account) => [account.id, account]));
    expect(byId.get(accounts[0] ?? "")?.activeSessions).toBe(2);
    expect(byId.get(accounts[0] ?? "")?.cooldownUntil).toBeNull();
    // A binding idle beyond the load window no longer counts.
    expect(byId.get(accounts[1] ?? "")?.activeSessions).toBe(0);
    expect(byId.get(accounts[1] ?? "")?.cooldownUntil).not.toBeNull();
  });

  dbTest("routes without stickiness while the session table is missing", async () => {
    if (!sql) throw new Error("no sql client");
    await insertAccounts(2);
    await sql`alter table coderouter_session_accounts rename to coderouter_session_accounts_gone`;
    try {
      const placed = await selectAccountForSession({
        teamId: TEAM,
        provider: "codex",
        sessionKey: "pre-migration-session",
      });
      expect(placed).not.toBeNull();
      expect(placed?.sticky).toBe(false);
      const again = await selectAccountForSession({
        teamId: TEAM,
        provider: "codex",
        sessionKey: "pre-migration-session",
      });
      expect(again).not.toBeNull();
    } finally {
      await sql`alter table coderouter_session_accounts_gone rename to coderouter_session_accounts`;
    }
  });

  dbTest("bind is last-write-wins for a session key", async () => {
    const accounts = await insertAccounts(2);
    await bindSessionAccount(TEAM, "codex", "raced-session", accounts[0] ?? "");
    await bindSessionAccount(TEAM, "codex", "raced-session", accounts[1] ?? "");
    const bound = await findSessionAccount(TEAM, "codex", "raced-session", []);
    expect(bound?.id).toBe(accounts[1] ?? "");
  });
});

describe("coderouter route token VM binding db behavior", () => {
  dbTest("a token issued for a VM authenticates with that binding", async () => {
    const { token } = await issueRouteToken(TEAM, "user-1", "vm", { vmId: "vm-1" });
    await expect(authenticateRouteToken(token)).resolves.toEqual({
      teamId: TEAM,
      stackUserId: "user-1",
      vmId: "vm-1",
    });
  });

  dbTest("an unbound token binds once and never moves", async () => {
    const { token } = await issueRouteToken(TEAM, "user-1");
    await expect(authenticateRouteToken(token)).resolves.toMatchObject({ vmId: null });
    await expect(bindRouteTokenToVm("other-team", token, "vm-1")).resolves.toBe(false);
    await expect(bindRouteTokenToVm(TEAM, token, "vm-1")).resolves.toBe(true);
    await expect(bindRouteTokenToVm(TEAM, token, "vm-2")).resolves.toBe(false);
    await expect(authenticateRouteToken(token)).resolves.toMatchObject({ vmId: "vm-1" });
  });

  dbTest("revoking a VM's tokens leaves other tokens live", async () => {
    const bound = await issueRouteToken(TEAM, "user-1", "vm", { vmId: "vm-1" });
    const other = await issueRouteToken(TEAM, "user-1", "vm", { vmId: "vm-2" });
    const cli = await issueRouteToken(TEAM, "user-1");
    await revokeRouteTokensForVm("vm-1");
    await expect(authenticateRouteToken(bound.token)).resolves.toBeNull();
    await expect(authenticateRouteToken(other.token)).resolves.toMatchObject({ vmId: "vm-2" });
    await expect(authenticateRouteToken(cli.token)).resolves.toMatchObject({ vmId: null });
    await expect(bindRouteTokenToVm(TEAM, bound.token, "vm-3")).resolves.toBe(false);
  });
});
