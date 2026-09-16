// Operator E2E: a disposable Stack user, two teams, and one real Freestyle VM.
// Run against an isolated dev backend, never a customer/production database.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { StackServerApp } from "@stackframe/stack";

const origin = required("CMUX_SCOPE_E2E_ORIGIN");
const sqlHost = required("CMUX_SCOPE_E2E_SQL_HOST");
const sqlContainer = required("CMUX_SCOPE_E2E_SQL_CONTAINER");
if (!/^cmux-dev-[a-z0-9-]+$/.test(sqlContainer) || !/^[a-z0-9._-]+@[a-z0-9.-]+$/i.test(sqlHost)) throw new Error("E2E requires an isolated cmux-dev database");
const app = new StackServerApp({ tokenStore: "memory", projectId: required("NEXT_PUBLIC_STACK_PROJECT_ID"),
  publishableClientKey: required("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"), secretServerKey: required("STACK_SECRET_SERVER_KEY") });
const q = (value: string) => "'" + value.replaceAll("'", "''") + "'";
function sql(statement: string) {
  return execFileSync("ssh", ["-o", "BatchMode=yes", sqlHost, "docker", "exec", "-i", sqlContainer,
    "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "cmux", "-d", "cmux", "-At"], { input: statement, encoding: "utf8" }).trim();
}
const checks: string[] = [];
function passed(name: string) { checks.push(name); console.log(`PASS ${name}`); }
const suffix = randomBytes(5).toString("hex");
let vmId: string | null = null;
let user: Awaited<ReturnType<typeof app.createUser>> | null = null;
let member: Awaited<ReturnType<typeof app.createUser>> | null = null;
let teamA: Awaited<ReturnType<typeof app.createTeam>> | null = null;
let teamB: Awaited<ReturnType<typeof app.createTeam>> | null = null;
let headers: Record<string, string> = {};
async function api(path: string, body?: unknown, method = body === undefined ? "GET" : "POST") {
  const response = await fetch(new URL(path, origin), { method, headers: { ...headers, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(180_000) });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${text.slice(0, 800)}`);
  return text ? JSON.parse(text) : null;
}
async function guest(command: string) {
  const result = await api(`/api/vm/${vmId}/exec`, { command, timeoutMs: 90_000 });
  if (result.exitCode !== 0) throw new Error(`guest command failed: ${JSON.stringify(result).slice(0, 1600)}`);
  return result.stdout as string;
}
try {
  user = await app.createUser({ displayName: `VM scope E2E ${suffix}`, primaryEmail: `cmux-vm-scope+${suffix}@manaflow.dev`,
    primaryEmailVerified: true, primaryEmailAuthEnabled: true, password: randomBytes(24).toString("base64url"),
    clientReadOnlyMetadata: { cmuxVmPlan: "pro" } });
  teamA = await user.createTeam({ displayName: `VM scope A ${suffix}` });
  teamB = await user.createTeam({ displayName: `VM scope B ${suffix}` });
  const session = await user.createSession({ expiresInMillis: 60 * 60 * 1000, isImpersonation: true });
  const tokens = await session.getTokens();
  assert(tokens.accessToken && tokens.refreshToken);
  headers = { authorization: `Bearer ${tokens.accessToken}`, "x-stack-refresh-token": tokens.refreshToken, "x-cmux-team-id": teamA.id };
  const created = await api('/api/vm', { provider: 'freestyle', memoryMb: 4096, billingTeamId: teamA.id });
  vmId = created.id;
  assert(vmId);
  console.log(`Created disposable VM ${vmId}`);
  sql(`insert into coderouter_accounts (team_id, provider, provider_account_id, label, visibility, created_by) values
    (${q(teamA.id)}, 'openai-apikey', 'e2e-shared-a', 'Shared A', 'team', ${q(user.id)}),
    (${q(teamA.id)}, 'openai-apikey', 'e2e-private-a', 'Private A', 'private', ${q(user.id)}),
    (${q(teamB.id)}, 'openai-apikey', 'e2e-shared-b', 'Shared B', 'team', ${q(user.id)});
    insert into coderouter_claude_accounts (team_id, kind, label, identifier, visibility, created_by, ciphertext, nonce, auth_tag, encrypted_data_key, kms_key_id) values
    (${q(teamA.id)}, 'anthropic_api_key', 'Claude A', 'fixture', 'team', ${q(user.id)}, 'x', 'x', 'x', 'x', 'x'),
    (${q(teamB.id)}, 'anthropic_api_key', 'Claude B', 'fixture', 'team', ${q(user.id)}, 'x', 'x', 'x', 'x', 'x');`);
  // Force the real driver's guest-CLI heal before invoking the new command.
  await api(`/api/vm/${vmId}/attach-endpoint`, { transport: 'cmux-remote' });
  const env = '. /etc/cmux/model-plane.env; ';
  const list = JSON.parse(await guest(env + 'cmux coderouter accounts --json'));
  assert.equal(list.teamId, teamA.id);
  assert.deepEqual(list.accounts.map((a: { label: string }) => a.label).sort(), ['Claude A', 'Shared A']);
  passed('real guest lists only its team shared accounts across native and Claude catalogs');
  const org = JSON.parse(await guest(env + 'cmux coderouter org current --json'));
  assert.deepEqual(org, { teamId: teamA.id, fixed: true });
  passed('real guest organization is fixed to its VM team');
  const forged = JSON.parse(await guest(env + `curl -fsS -H ${q('x-cmux-team-id: '+teamB.id)} "$CMUX_CODEROUTER_URL/api/coderouter/accounts?teamId=${teamB.id}"`));
  assert.equal(forged.teamId, teamA.id);
  assert.deepEqual(forged.accounts.map((a: { label: string }) => a.label), ['Shared A']);
  passed('query and header attempts to select the creator’s other team are ignored');
  assert.equal((await guest(env + 'curl -sS -o /dev/null -w "%{http_code}" -X POST "$CMUX_CODEROUTER_URL/api/coderouter/session"')).trim(), '403');
  passed('guest cannot mint another organization session');
  const privateAccountId = sql(`select id from coderouter_accounts where team_id = ${q(teamA.id)} and provider_account_id = 'e2e-private-a'`);
  await api(`/api/coderouter/accounts/${privateAccountId}/sharing`, { family: 'native', visibility: 'team' }, 'PATCH');
  const sharedList = JSON.parse(await guest(env + 'cmux coderouter accounts --json'));
  assert(sharedList.accounts.some((account: { label: string }) => account.label === 'Private A'));
  await api(`/api/coderouter/accounts/${privateAccountId}/sharing`, { family: 'native', visibility: 'private' }, 'PATCH');
  passed('team administrator can explicitly share and unshare a private import');
  member = await app.createUser({ displayName: `VM scope member ${suffix}` });
  await teamA.addUser(member.id);
  assert.equal(await member.hasPermission(teamA, "$manage_api_keys"), false);
  const memberTokens = await (await member.createSession({ expiresInMillis: 600_000, isImpersonation: true })).getTokens();
  const denied = await fetch(new URL(`/api/coderouter/accounts/${privateAccountId}/sharing`, origin), {
    method: 'PATCH', headers: { authorization: `Bearer ${memberTokens.accessToken}`, 'x-stack-refresh-token': memberTokens.refreshToken!,
      'x-cmux-team-id': teamA.id, 'content-type': 'application/json' }, body: JSON.stringify({ family: 'native', visibility: 'team' }),
  });
  assert.equal(denied.status, 403);
  passed('ordinary team membership cannot administer provider accounts');
  // Remove every eligible model account. Private and other-team accounts must
  // never become fallback candidates, including after a pool grant is removed.
  sql(`delete from coderouter_pool_accounts where team_id = ${q(teamA.id)};`);
  assert.equal((await guest(env + 'curl -sS -o /tmp/scope-model.json -w "%{http_code}" "$CMUX_CODEROUTER_URL/v1/models"')).trim(), '503');
  const empty = JSON.parse(await guest(env + 'cmux coderouter accounts --json'));
  assert.equal(empty.accounts.length, 0);
  assert.equal(sql(`select count(*) from coderouter_accounts where team_id in (${q(teamA.id)},${q(teamB.id)}) and last_used_at is not null`), '0');
  passed('model routing fails closed after revocation without using private or foreign accounts');
  console.log(JSON.stringify({ kind: 'passed', vmId, checks }, null, 2));
} finally {
  if (vmId) {
    try { await api(`/api/vm/${vmId}`, undefined, 'DELETE'); console.log('Deleted disposable VM'); }
    catch (error) { console.error('VM cleanup failed:', error instanceof Error ? error.message : 'unknown'); process.exitCode = 1; }
  }
  if (teamA && teamB) {
    sql(`delete from coderouter_accounts where team_id in (${q(teamA.id)},${q(teamB.id)});
      delete from coderouter_claude_accounts where team_id in (${q(teamA.id)},${q(teamB.id)});`);
  }
  await teamA?.delete();
  await teamB?.delete();
  await member?.delete();
  await user?.delete();
}
function required(name: string) { const value = process.env[name]?.trim(); if (!value) throw new Error(`${name} is required`); return value; }
