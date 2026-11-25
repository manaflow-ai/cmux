/**
 * CI trust (src/auth/ci-trust.ts): a GitHub Actions job authenticates with its
 * OIDC token, no stored key. Only a token GitHub signed whose audience,
 * repository, environment and workflow ref all match a trust row gets in, as
 * that row's own service principal: one team, its labels, at most maxVms VMs,
 * and every VM it creates pauses within the run cap and is deleted once stopped.
 */
import { generateKeyPair } from "jose";
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";
import { parseCiTrust } from "../../src/auth/ci-trust.ts";
import { withCiTeamQuotas } from "../../src/policy.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TEAM = "cmux-vm-product-smoke";
const WORKFLOW = "manaflow-ai/cmux/.github/workflows/cmux-vm.yml@refs/heads/feat-cmux-next";
const ROW = {
  id: "ci-product-smoke",
  audience: "https://vm.test",
  repository: "manaflow-ai/cmux",
  environment: "cmux-vm-production",
  workflowRef: WORKFLOW,
  team: TEAM,
  scopes: ["vm:read", "vm:write", "vm:exec"],
  labels: { "cmux.ci": "product-smoke" },
  maxVms: 1,
  maxUsdPerHour: 1,
  maxRunSeconds: 900,
};
const CLAIMS = {
  repository: "manaflow-ai/cmux",
  environment: "cmux-vm-production",
  workflow_ref: WORKFLOW,
  sub: "repo:manaflow-ai/cmux:environment:cmux-vm-production",
};
const IMAGE = { id: "cloud-native", revision: "r1" };
const SNAPSHOT = "operator-image-fixture";

let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  current = await makeHarness({
    environment: "production",
    ciTrust: JSON.stringify([ROW]),
    bootImages: JSON.stringify([{ ...IMAGE, displayName: "Cloud Native", snapshotId: SNAPSHOT, services: ["ci-product-smoke"] }]),
    policyEntitlements: { entitledServiceIds: ["ci-product-smoke"] },
    ...options,
  });
  current.upstream.snapshots.set(SNAPSHOT, { id: SNAPSHOT, sourceVmId: "operator-image-source", autoDeleteSeconds: null });
  return current;
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

const create = (t: Harness, token: string, body: Record<string, unknown> = {}, headers: Record<string, string> = {}) =>
  t.request("/v1/vms", { ...bearer(token), ...headers }, { method: "POST", body: { image: IMAGE, labels: { role: "cloud" }, ...body } });

describe("CI trust rows", () => {
  it("parses rows and refuses one that could reach past VM scopes or carries no label", () => {
    expect(parseCiTrust(JSON.stringify([ROW])).rows).toHaveLength(1);
    expect(parseCiTrust(undefined)).toEqual({ ok: true, rows: [] });
    for (const bad of [
      { ...ROW, scopes: ["vm:read", "admin"] },
      { ...ROW, scopes: ["acl:write"] },
      { ...ROW, labels: {} },
      { ...ROW, id: "cloud-platform-production" },
      { ...ROW, maxVms: 50 },
      { ...ROW, maxRunSeconds: 86_400 },
      { ...ROW, workflowRef: "manaflow-ai/cmux/.github/workflows/cmux-vm.yml" },
    ]) {
      expect(parseCiTrust(JSON.stringify([bad])).ok, JSON.stringify(bad)).toBe(false);
    }
    expect(parseCiTrust(JSON.stringify([ROW, ROW])).ok).toBe(false);
  });
});

describe("a trusted job", () => {
  it("creates on the product path: its team, never-pause idle, the approved image, its labels and the run cap", async () => {
    const t = await harness();
    const token = await t.githubToken(CLAIMS);
    const response = await create(t, token, {}, { "x-cmux-team-id": TEAM });
    expect(response.status).toBe(201);
    const vm = await response.json<{ labels: Record<string, string>; idleTimeoutSeconds: number | null; bootImage: unknown }>();
    expect(vm.labels).toMatchObject({ role: "cloud", "cmux.ci": "product-smoke" });
    expect(vm.idleTimeoutSeconds === null || vm.idleTimeoutSeconds < 0).toBe(true);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ maxRunSeconds: 900, autoDeleteSeconds: 0 });
    expect(vm.bootImage).toMatchObject(IMAGE);
    const audit = t.audit.find((row) => row.action === "vm.create");
    expect(audit).toMatchObject({ tenantId: TEAM, actor: "service:ci-product-smoke" });
  });

  it("keeps a shorter run cap it asks for and replaces no cap or a longer one", async () => {
    const t = await harness({ ciTrust: JSON.stringify([{ ...ROW, maxVms: 3 }]) });
    const token = await t.githubToken(CLAIMS);
    for (const asked of [120, -1, 7200]) {
      expect((await create(t, token, { maxRunSeconds: asked, autoDeleteSeconds: -1 })).status).toBe(201);
    }
    const sent = t.upstream.callsTo("POST", /^\/v5\/vms$/);
    expect(sent).toHaveLength(3);
    expect(sent[0]?.json).toMatchObject({ maxRunSeconds: 120, autoDeleteSeconds: 0 });
    expect(sent[1]?.json).toMatchObject({ maxRunSeconds: 900, autoDeleteSeconds: 0 });
    expect(sent[2]?.json).toMatchObject({ maxRunSeconds: 900, autoDeleteSeconds: 0 });
  });

  it("stops at its live VM cap and may not fork", async () => {
    const t = await harness();
    const token = await t.githubToken(CLAIMS);
    const first = await create(t, token);
    expect(first.status).toBe(201);
    expect((await create(t, token)).status).toBe(429);
    const { id } = await first.json<{ id: string }>();
    expect((await t.request(`/v1/vms/${id}/fork`, bearer(token), { method: "POST", body: {} })).status).toBe(403);
  });

  it("accepts a token that also names the same file as job_workflow_ref", async () => {
    const t = await harness();
    expect((await create(t, await t.githubToken({ ...CLAIMS, job_workflow_ref: WORKFLOW }))).status).toBe(201);
  });

  it("may not choose its VM's size, so its spend is maxVms VMs of the default or image size", async () => {
    const t = await harness();
    const token = await t.githubToken(CLAIMS);
    for (const resources of [{ vcpus: 16, memoryMib: 8192 }, { vcpus: 2, memoryMib: 49152 }, { diskMib: 65536 }]) {
      expect((await create(t, token, { resources })).status, JSON.stringify(resources)).toBe(403);
    }
    const snapshot = t.addSnapshot(TEAM);
    expect((await create(t, token, { image: undefined, snapshotId: snapshot.snapshotId })).status).toBe(403);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
    expect((await create(t, token)).status).toBe(201);
  });

  it("reclaims its quota from VMs the provider already deleted (a job cancelled before its cleanup)", async () => {
    const t = await harness();
    const token = await t.githubToken(CLAIMS);
    expect((await create(t, token)).status).toBe(201);
    expect((await create(t, token)).status).toBe(429);
    // The run cap paused it and the provider auto-deleted it; its row still counts until the Worker forgets it.
    t.upstream.vms.clear();
    expect((await create(t, token)).status).toBe(201);
    expect(t.audit.filter((row) => row.action === "vm.delete" && row.actor === "service:ci-product-smoke")).toHaveLength(1);
  });

  it("may not grow a VM past what it was created with", async () => {
    const t = await harness();
    const token = await t.githubToken(CLAIMS);
    const { id } = await (await create(t, token)).json<{ id: string }>();
    const response = await t.request(`/v1/vms/${id}/resize`, bearer(token), { method: "POST", body: { resources: { vcpus: 16, memoryMib: 65536 } } });
    expect(response.status).toBe(403);
    expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(0);
  });

  it("caps its team's quota at the row's maxVms, so the atomic tenant ledger holds the limit under concurrency", () => {
    const rows = [{ team: TEAM, maxVms: 2 }];
    expect(withCiTeamQuotas({}, rows)).toEqual({ [TEAM]: 2 });
    expect(withCiTeamQuotas({ [TEAM]: 20, other: 5 }, rows)).toEqual({ [TEAM]: 2, other: 5 });
    expect(withCiTeamQuotas({ [TEAM]: 1 }, rows)).toEqual({ [TEAM]: 1 });
  });

  it("may not act for another team or reach that team's VMs", async () => {
    const t = await harness();
    const other = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
    const theirs = await (await t.request("/v1/vms", bearer(other), { method: "POST", body: {} })).json<{ id: string }>();
    const token = await t.githubToken(CLAIMS);
    expect((await create(t, token, {}, { "x-cmux-team-id": "team_alpha" })).status).toBe(403);
    expect((await t.request(`/v1/vms/${theirs.id}`, bearer(token))).status).toBe(404);
  });
});

describe("tokens that match no row", () => {
  const refused: ReadonlyArray<readonly [string, (t: Harness) => Promise<string>]> = [
    ["another repository", (t) => t.githubToken({ ...CLAIMS, repository: "someone/cmux" })],
    ["another environment", (t) => t.githubToken({ ...CLAIMS, environment: "cmux-vm-staging" })],
    ["no environment", (t) => t.githubToken({ repository: CLAIMS.repository, workflow_ref: WORKFLOW })],
    ["no workflow_ref", (t) => t.githubToken({ repository: CLAIMS.repository, environment: CLAIMS.environment, job_workflow_ref: WORKFLOW })],
    ["another branch", (t) => t.githubToken({ ...CLAIMS, workflow_ref: WORKFLOW.replace("feat-cmux-next", "lane/evil") })],
    ["another workflow", (t) => t.githubToken({ ...CLAIMS, workflow_ref: WORKFLOW.replace("cmux-vm.yml", "other.yml") })],
    ["a job from another reusable workflow", (t) => t.githubToken({ ...CLAIMS, job_workflow_ref: "manaflow-ai/cmux/.github/workflows/other.yml@refs/heads/feat-cmux-next" })],
    ["another audience", (t) => t.githubToken(CLAIMS, { audience: "https://elsewhere.test" })],
    ["an expired token", (t) => t.githubToken(CLAIMS, { issuedAt: Math.floor(Date.now() / 1000) - 600, expiresIn: "-120s" })],
    ["an old token", (t) => t.githubToken(CLAIMS, { issuedAt: Math.floor(Date.now() / 1000) - 3600, expiresIn: "1h" })],
    ["a token signed by another key", async (t) => t.githubToken(CLAIMS, { key: (await generateKeyPair("RS256")).privateKey })],
  ];
  for (const [what, mint] of refused) {
    it(`refuses ${what} with 401 and calls nothing upstream`, async () => {
      const t = await harness();
      expect((await create(t, await mint(t))).status).toBe(401);
      expect(t.upstreamRequests).toHaveLength(0);
    });
  }

  it("refuses every GitHub token when no row is configured", async () => {
    const t = await harness({ ciTrust: "" });
    expect((await create(t, await t.githubToken(CLAIMS))).status).toBe(401);
  });

  it("leaves session tokens to Stack", async () => {
    const t = await harness();
    t.addMember("team_alpha", "user_1");
    const session = await t.sessionToken("user_1");
    expect((await t.request("/v1/vms", { ...bearer(session), "x-cmux-team-id": "team_alpha" })).status).toBe(200);
  });
});
