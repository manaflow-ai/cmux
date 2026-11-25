/**
 * Team keys (src/auth/team-keys.ts): a long-lived key from the CMUX_VM_TEAM_KEYS var that acts for its one team with
 * no X-Cmux-Team-Id and no person signed in, reaches only VMs carrying its labels, and is held to its maxVms and
 * maxUsdPerHour caps on every create; an over-cap create is 429 naming the cap. Its optional maxRunningVms,
 * maxUsdPerDay and maxUsdPerMonth caps (RFD 0016) hold on every create, start and resume, and each refusal names the
 * cap and its current value; unset, they change nothing. Its VMs outlive a key rotation.
 */
import { Effect } from "effect";
import { afterEach, describe, expect, it } from "vitest";
import { generateApiKey, hashApiKey } from "../../src/auth/credentials.ts";
import { parseTeamKeys } from "../../src/auth/team-keys.ts";
import { estimatedSpendUsd, spendWindows } from "../../src/domain/agents.ts";
import { teamKeysOf, type ServiceKey } from "../../src/auth/service-keys.ts";
import { newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TEAM = "team_alpha";
const LABELS = { "cmux.team-key": "lanes" };
const NO_HASHES: string[] = [];
const ROW = {
  id: "tk-lanes",
  team: TEAM,
  sha256: NO_HASHES,
  scopes: ["vm:read", "vm:write", "vm:exec"],
  labels: LABELS,
  maxVms: 2,
  maxUsdPerHour: 10,
};
const HASH = "a".repeat(64);

const sha = (key: string) => Effect.runPromise(hashApiKey(key));

let current: Harness | undefined;
/** A harness with one team key row; answers it and its secrets (one per hash). */
type Caps = { maxRunningVms?: number; maxUsdPerDay?: number; maxUsdPerMonth?: number };
const harness = async (row: Partial<typeof ROW> & Caps = {}, keys = 1, options: HarnessOptions = {}) => {
  const secrets = Array.from({ length: keys }, () => generateApiKey());
  const teamKeys = JSON.stringify([{ ...ROW, ...row, sha256: await Promise.all(secrets.map(sha)) }]);
  current = await makeHarness({ teamKeys, ...options });
  return { t: current, secrets };
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

const create = (t: Harness, secret: string, body: Record<string, unknown> = {}, headers: Record<string, string> = {}) =>
  t.request("/v1/vms", { ...bearer(secret), ...headers }, { method: "POST", body });

describe("CMUX_VM_TEAM_KEYS", () => {
  it("parses a row into one key per hash and refuses one past VM scopes, labels, its caps or a third hash", () => {
    const parsed = parseTeamKeys(JSON.stringify([{ ...ROW, sha256: [HASH, "b".repeat(64)] }]));
    expect(parsed.ok).toBe(true);
    expect(parsed.keys.map((key) => key.budget)).toEqual([
      { maxVms: 2, maxUsdPerHour: 10, holder: "team key tk-lanes" },
      { maxVms: 2, maxUsdPerHour: 10, holder: "team key tk-lanes" },
    ]);
    expect(parseTeamKeys(undefined)).toEqual({ ok: true, keys: [] });
    const capped = parseTeamKeys(JSON.stringify([{ ...ROW, sha256: [HASH], maxRunningVms: 1, maxUsdPerDay: 5, maxUsdPerMonth: 50 }]));
    expect(capped.keys.map((key) => key.budget)).toEqual([
      { maxVms: 2, maxUsdPerHour: 10, maxRunningVms: 1, maxUsdPerDay: 5, maxUsdPerMonth: 50, holder: "team key tk-lanes" },
    ]);
    for (const bad of [
      { ...ROW, sha256: [] },
      { ...ROW, sha256: [HASH, "b".repeat(64), "c".repeat(64)] },
      { ...ROW, sha256: ["not-a-hash"] },
      { ...ROW, scopes: ["vm:read", "admin"] },
      { ...ROW, scopes: ["acl:write"] },
      { ...ROW, labels: {} },
      { ...ROW, id: "lanes" },
      { ...ROW, maxVms: 0 },
      { ...ROW, maxVms: 501 },
      { ...ROW, maxUsdPerHour: 0 },
      { ...ROW, maxUsdPerHour: 501 },
      { ...ROW, maxRunningVms: 0 },
      { ...ROW, maxRunningVms: 501 },
      { ...ROW, maxRunningVms: 1.5 },
      { ...ROW, maxUsdPerDay: 0 },
      { ...ROW, maxUsdPerDay: 12_001 },
      { ...ROW, maxUsdPerMonth: -1 },
      { ...ROW, maxUsdPerMonth: 372_001 },
    ]) {
      expect(parseTeamKeys(JSON.stringify([bad])).ok, JSON.stringify(bad)).toBe(false);
    }
    expect(parseTeamKeys(JSON.stringify([{ ...ROW, sha256: [HASH] }, { ...ROW, sha256: ["b".repeat(64)] }])).ok).toBe(false);
    expect(parseTeamKeys(JSON.stringify([{ ...ROW, sha256: [HASH] }, { ...ROW, id: "tk-other", sha256: [HASH] }])).ok).toBe(false);
  });

  it("disables every team key when one reuses a service key's id or hash", () => {
    const service: ServiceKey = { id: "tk-lanes", sha256: "b".repeat(64), scopes: new Set(), labels: { role: "chief" }, teams: null };
    expect(teamKeysOf([service], JSON.stringify([{ ...ROW, sha256: [HASH] }]))).toEqual([]);
    expect(teamKeysOf([{ ...service, id: "chief" }], JSON.stringify([{ ...ROW, sha256: ["b".repeat(64)] }]))).toEqual([]);
    expect(teamKeysOf([{ ...service, id: "chief" }], JSON.stringify([{ ...ROW, sha256: [HASH] }]))).toHaveLength(1);
    expect(teamKeysOf([], "not json")).toEqual([]);
  });
});

describe("a team key", () => {
  it("creates headless for its team with no team header, labelled and audited as the key", async () => {
    const { t, secrets } = await harness();
    const response = await create(t, secrets[0]!, { labels: { role: "lane" } });
    expect(response.status).toBe(201);
    const vm = await response.json<{ id: string; labels: Record<string, string> }>();
    expect(vm.labels).toEqual({ role: "lane", ...LABELS });
    expect(t.resources.find((row) => row.cmuxId === vm.id)).toMatchObject({ tenantId: TEAM, createdBy: "service:tk-lanes" });
    expect(t.audit).toContainEqual(expect.objectContaining({ tenantId: TEAM, actor: "service:tk-lanes", action: "vm.create", outcome: "ok" }));
    // Naming its own team is the same.
    expect((await create(t, secrets[0]!, {}, { "x-cmux-team-id": TEAM })).status).toBe(201);
  });

  it("refuses a create past maxVms with 429 naming the key and the cap", async () => {
    const { t, secrets } = await harness({ maxVms: 1 });
    expect((await create(t, secrets[0]!)).status).toBe(201);
    const over = await create(t, secrets[0]!);
    expect(over.status).toBe(429);
    const body = await over.json<{ message: string; budget: string }>();
    expect(body.budget).toBe("agent_vms");
    expect(body.message).toContain("team key tk-lanes");
    expect(body.message).toContain("has 1 live VMs, at its maxVms cap of 1");
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });

  it("refuses a create past maxUsdPerHour with 429 naming the cap", async () => {
    // The default size is estimated at 0.26 USD/h: one fits under 0.4, two do not.
    const { t, secrets } = await harness({ maxVms: 5, maxUsdPerHour: 0.4 });
    expect((await create(t, secrets[0]!)).status).toBe(201);
    const over = await create(t, secrets[0]!);
    expect(over.status).toBe(429);
    const body = await over.json<{ message: string; budget: string }>();
    expect(body.budget).toBe("agent_usd_per_hour");
    expect(body.message).toContain("team key tk-lanes");
    expect(body.message).toContain("maxUsdPerHour cap of 0.4 USD/h");
  });

  it("may not act for another team, reach the team's other VMs, or resize past its spend cap", async () => {
    const { t, secrets } = await harness();
    const other = await t.addKey(TEAM, ["vm:read", "vm:write"]);
    const theirs = await (await t.request("/v1/vms", bearer(other), { method: "POST", body: {} })).json<{ id: string }>();
    expect((await create(t, secrets[0]!, {}, { "x-cmux-team-id": "team_bravo" })).status).toBe(403);
    expect((await t.request(`/v1/vms/${theirs.id}`, bearer(secrets[0]!))).status).toBe(404);
    const { id } = await (await create(t, secrets[0]!)).json<{ id: string }>();
    const resize = await t.request(`/v1/vms/${id}/resize`, bearer(secrets[0]!), { method: "POST", body: { resources: { vcpus: 16, memoryMib: 32768 } } });
    expect(resize.status).toBe(403);
    expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(0);
  });

  it("keeps its VMs across a rotation: the second key reaches the first key's VM and shares its cap", async () => {
    const { t, secrets } = await harness({ maxVms: 1 }, 2);
    const { id } = await (await create(t, secrets[0]!)).json<{ id: string }>();
    expect((await t.request(`/v1/vms/${id}`, bearer(secrets[1]!))).status).toBe(200);
    expect((await create(t, secrets[1]!)).status).toBe(429);
  });

  it("cannot mint agent keys or keys of its own", async () => {
    const { t, secrets } = await harness();
    expect((await t.request("/v1/agent-keys", bearer(secrets[0]!), { method: "POST", body: { name: "sub" } })).status).toBe(403);
    expect((await t.request("/v1/api-keys", bearer(secrets[0]!), { method: "POST", body: { name: "sub", scopes: ["vm:read"] } })).status).toBe(403);
  });

  it("is refused when its row is gone or the var is invalid", async () => {
    const { t } = await harness();
    expect((await create(t, generateApiKey())).status).toBe(401);
    await t.dispose();
    const secret = generateApiKey();
    current = await makeHarness({ teamKeys: JSON.stringify([{ ...ROW, sha256: [await sha(secret)], maxVms: 9999 }]) });
    expect((await create(current, secret)).status).toBe(401);
  });

  it("creates on production when its team is under the manaflow-team flag", async () => {
    const { t, secrets } = await harness({}, 1, { environment: "production", policyEntitlements: { manaflowTenantIds: [TEAM] } });
    expect((await create(t, secrets[0]!)).status).toBe(201);
  });
});

describe("a team key's running and spend caps", () => {
  /** Back-dates the key's VM rows by `ms`, as if they were created that long ago. */
  const backdate = (t: Harness, ms: number) => {
    for (const [index, row] of t.resources.entries()) {
      if (row.kind === "vm") t.resources[index] = { ...row, createdAt: new Date(row.createdAt.getTime() - ms) };
    }
  };
  const refusal = async (response: Response) => {
    expect(response.status).toBe(429);
    return response.json<{ message: string; budget: string }>();
  };

  it("refuses a create, start or resume past maxRunningVms naming the cap and the running count; paused VMs do not count", async () => {
    const { t, secrets } = await harness({ maxVms: 5, maxRunningVms: 1 });
    const key = bearer(secrets[0]!);
    const { id } = await (await create(t, secrets[0]!)).json<{ id: string }>();
    const over = await refusal(await create(t, secrets[0]!));
    expect(over.budget).toBe("agent_running_vms");
    expect(over.message).toContain("team key tk-lanes has 1 running VMs, at its maxRunningVms cap of 1");
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
    // Booting the one already running is not a second running VM.
    expect((await t.request(`/v1/vms/${id}/start`, key, { method: "POST" })).status).toBe(200);
    expect((await t.request(`/v1/vms/${id}/pause`, key, { method: "POST" })).status).toBe(200);
    // Paused, it runs no more: a second fits, and then the first cannot resume or start past the cap.
    const second = await create(t, secrets[0]!);
    expect(second.status).toBe(201);
    const resume = await refusal(await t.request(`/v1/vms/${id}/resume`, key, { method: "POST" }));
    expect(resume.budget).toBe("agent_running_vms");
    expect(resume.message).toContain("has 1 running VMs, at its maxRunningVms cap of 1");
    expect((await refusal(await t.request(`/v1/vms/${id}/start`, key, { method: "POST" }))).budget).toBe("agent_running_vms");
    const { id: secondId } = await second.json<{ id: string }>();
    await t.request(`/v1/vms/${secondId}/start`, key, { method: "POST" });
    expect((await t.request(`/v1/vms/${secondId}/pause`, key, { method: "POST" })).status).toBe(200);
    expect((await t.request(`/v1/vms/${id}/resume`, key, { method: "POST" })).status).toBe(200);
  });

  it("refuses a create and a resume past maxUsdPerDay naming the cap and the estimated spend today", async () => {
    // 0.001 USD is ~14 s of a 4 vCPU / 8 GiB VM (0.26 USD/h): the milliseconds between these creates stay under it on a
    // slow runner, and the minute `backdate` adds goes past it. (0.000001 USD was ~14 ms, so a slow runner refused the
    // second create and its id came back undefined.)
    const { t, secrets } = await harness({ maxVms: 5, maxUsdPerDay: 0.001 });
    const key = bearer(secrets[0]!);
    // One VM runs for a minute; a second is paused (its span ends at its pause, so it costs nothing more).
    expect((await create(t, secrets[0]!)).status).toBe(201);
    const second = await create(t, secrets[0]!);
    expect(second.status).toBe(201);
    const { id } = await second.json<{ id: string }>();
    await t.request(`/v1/vms/${id}/start`, key, { method: "POST" });
    expect((await t.request(`/v1/vms/${id}/pause`, key, { method: "POST" })).status).toBe(200);
    backdate(t, 60_000);
    const over = await refusal(await create(t, secrets[0]!));
    expect(over.budget).toBe("agent_usd_per_day");
    expect(over.message).toMatch(/team key tk-lanes has spent an estimated \d+\.\d\d USD today \(UTC\), at its maxUsdPerDay cap of 0\.001 USD/);
    expect((await refusal(await t.request(`/v1/vms/${id}/resume`, key, { method: "POST" }))).budget).toBe("agent_usd_per_day");
  });

  it("counts deleted VMs toward maxUsdPerMonth", async () => {
    const { t, secrets } = await harness({ maxVms: 5, maxUsdPerMonth: 0.000001 });
    const { id } = await (await create(t, secrets[0]!)).json<{ id: string }>();
    backdate(t, 60_000);
    expect((await t.request(`/v1/vms/${id}`, bearer(secrets[0]!), { method: "DELETE" })).status).toBeLessThan(300);
    const over = await refusal(await create(t, secrets[0]!));
    expect(over.budget).toBe("agent_usd_per_month");
    expect(over.message).toContain("this month (UTC), at its maxUsdPerMonth cap of 0.000001 USD");
  });

  /** An ownership row of the key's for provider VM `upstreamId`, created `ago` ms back (as if made before a cap change). */
  const ownedRow = (t: Harness, upstreamId: string, ago: number) => {
    const cmuxId = newVmId();
    t.resources.push({ tenantId: TenantId.make(TEAM), kind: "vm", cmuxId, upstreamId: UpstreamId.make(upstreamId), createdBy: "service:tk-lanes", createdAt: new Date(Date.now() - ago), displayName: null, labels: LABELS });
    return cmuxId;
  };

  it("prices a VM gone at the provider from its create to now, so its spend does not vanish", async () => {
    const { t, secrets } = await harness({ maxVms: 5, maxUsdPerDay: 0.000001 });
    ownedRow(t, "vm-gone-at-provider", 60_000);
    expect((await refusal(await create(t, secrets[0]!))).budget).toBe("agent_usd_per_day");
  });

  it("counts every live VM on a start, not only the newest maxVms + 1", async () => {
    // maxVms lowered to 1 after the key made three: the oldest runs, the two newest are paused.
    const { t, secrets } = await harness({ maxVms: 1, maxRunningVms: 1 });
    ownedRow(t, t.upstream.addVm("running").id, 3_600_000);
    ownedRow(t, t.upstream.addVm("paused").id, 120_000);
    const newest = ownedRow(t, t.upstream.addVm("paused").id, 60_000);
    const over = await refusal(await t.request(`/v1/vms/${newest}/start`, bearer(secrets[0]!), { method: "POST" }));
    expect(over.budget).toBe("agent_running_vms");
    expect(over.message).toContain("has 1 running VMs, at its maxRunningVms cap of 1");
  });

  it("leaves a key with none of these caps as it was: start and resume read nothing extra", async () => {
    const { t, secrets } = await harness({ maxVms: 5 });
    const key = bearer(secrets[0]!);
    const { id } = await (await create(t, secrets[0]!)).json<{ id: string }>();
    await t.request(`/v1/vms/${id}/start`, key, { method: "POST" });
    expect((await t.request(`/v1/vms/${id}/pause`, key, { method: "POST" })).status).toBe(200);
    backdate(t, 3_600_000);
    expect((await create(t, secrets[0]!)).status).toBe(201);
    const reads = t.upstream.callsTo("GET", new RegExp(`/v5/vms/[^/]*$`)).length;
    expect((await t.request(`/v1/vms/${id}/start`, key, { method: "POST" })).status).toBe(200);
    expect(t.upstream.callsTo("GET", new RegExp(`/v5/vms/[^/]*$`)).length).toBe(reads);
  });
});

describe("spend estimate", () => {
  it("prices each span for its time inside the window, up to now", () => {
    const now = Date.UTC(2026, 10, 22, 12, 0, 0);
    const { dayStartMs, monthStartMs } = spendWindows(now);
    expect(dayStartMs).toBe(Date.UTC(2026, 10, 22));
    expect(monthStartMs).toBe(Date.UTC(2026, 10, 1));
    const hour = 3_600_000;
    const spans = [
      { usdPerHour: 1, fromMs: now - 2 * hour, toMs: null },
      { usdPerHour: 2, fromMs: dayStartMs - hour, toMs: dayStartMs + hour },
      { usdPerHour: 4, fromMs: monthStartMs - hour, toMs: dayStartMs - hour },
    ];
    expect(estimatedSpendUsd(spans, dayStartMs, now)).toBeCloseTo(2 + 2);
    expect(estimatedSpendUsd(spans, monthStartMs, now)).toBeCloseTo(2 + 4 + 4 * (21 * 24 - 1));
  });
});
