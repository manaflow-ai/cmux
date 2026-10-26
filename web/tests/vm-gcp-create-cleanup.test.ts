import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { GcpProvider } from "../services/vms/drivers/gcp";
import { SecretBytes, wipeProviderCredential, type ProviderCredential } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import { enforceVmIdlePause } from "../services/vms/idlePauseJob";
import { VM_CREATE_ABANDONED_AFTER_MS } from "../services/vms/operationTimeouts";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import {
  createVm,
  destroyVm,
  drainProviderCreateCleanups,
  getVm,
  reconcileVmProviderStatuses,
} from "../services/vms/workflows";

// The invariant: a GCP create cannot leave an instance nothing will ever
// delete. The server keeps no GCP credential, so every delete it owes runs on
// a later request that carries the user's own short-lived token.

const runDbTests = process.env.CMUX_DB_TEST === "1";
const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = runDbTests ? serialTest : test.skip;
const labsOn = { CMUX_VM_GCP_LABS_ENABLED: "1", CMUX_VM_GCP_ENABLED: "1" };
const PROJECT = "user-project";
const ZONE = "us-west1-b";

let sql: Sql | null = null;

const previousEnv = { ...process.env };

beforeAll(() => {
  if (!runDbTests) return;
  // The drain is behind the same Labs gate as every Compute Engine call.
  Object.assign(process.env, labsOn);
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL ?? "", { max: 1 });
});

beforeEach(async () => {
  if (sql) await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
});

afterAll(async () => {
  for (const key of Object.keys(labsOn)) {
    if (previousEnv[key] === undefined) delete process.env[key];
    else process.env[key] = previousEnv[key];
  }
  await closeCloudDbForTests();
  await sql?.end();
});

function credential(token: string): ProviderCredential {
  return {
    provider: "gcp",
    accessToken: new SecretBytes(new TextEncoder().encode(token)),
    expiresAtUnix: Math.floor(Date.now() / 1000) + 3_600,
    lifetime: new AbortController(),
    sshPublicKey: "ssh-ed25519 AAAA test",
    sshPrivateKeyPem: new SecretBytes(new TextEncoder().encode("PRIVATE KEY")),
  };
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

/** A Compute Engine fake whose insert is accepted and whose operation poll never finishes. */
function computeEngine() {
  const instances = new Set<string>();
  const sent: Array<{ readonly method: string; readonly path: string; readonly token: string }> = [];
  let inserted!: () => void;
  const insertAccepted = new Promise<void>((resolve) => { inserted = resolve; });
  const fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const method = init?.method ?? "GET";
    const path = new URL(String(input)).pathname.replace(/^\/compute\/v1/, "");
    const token = String((init?.headers as Record<string, string>).authorization ?? "");
    sent.push({ method, path, token });
    const instance = /^\/projects\/[^/]+\/zones\/[^/]+\/instances\/([^/]+)$/.exec(path)?.[1];
    if (method === "POST" && path.endsWith("/instances")) {
      instances.add(JSON.parse(String(init?.body)).name);
      inserted();
      return Promise.resolve(json({ name: "insert-op", status: "RUNNING", zone: ZONE }));
    }
    if (method === "DELETE" && instance) {
      if (!instances.delete(instance)) return Promise.resolve(json({}, 404));
      return Promise.resolve(json({ name: "delete-op", status: "DONE" }));
    }
    if (method === "GET" && instance) {
      return Promise.resolve(instances.has(instance) ? json({ name: instance, status: "RUNNING" }) : json({}, 404));
    }
    // The insert operation is still running when the request's credential goes away.
    return new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
    });
  };
  return { fetch, instances, sent, insertAccepted };
}

function gcpGateway(driver: GcpProvider, calls: string[] = []): VmProviderGatewayShape {
  const op = <A>(operation: string, run: () => Promise<A>) => {
    calls.push(operation);
    return Effect.tryPromise({
      try: run,
      catch: (cause) => new VmProviderOperationError({ provider: "gcp", operation, cause }),
    });
  };
  return {
    supportsPrivateNetworking: () => true,
    ensureNetwork: (_provider, options) => Effect.succeed({
      // Provider network ids are unique per row; one per owner here.
      id: `projects/${PROJECT}/global/networks/${options.slug}`,
      slug: options.slug,
      cidr: "10.240.0.0/16",
      cidrV6: "fd00:240::/64",
    }),
    create: (_provider, options) => op("create", () => driver.create(options)),
    destroy: (_provider, vmId, local) => op("destroy", () => driver.destroy(vmId, local)),
    getStatus: (_provider, vmId, local) => op("getStatus", () => driver.getStatus(vmId, { credential: local })),
    pause: (_provider, vmId, local) => op("pause", () => driver.pause(vmId, local)),
    exec: () => op("exec", () => Promise.reject(new Error("exec is unavailable"))),
    openAttach: () => op("openAttach", () => Promise.reject(new Error("openAttach is unavailable"))),
    openSSH: () => op("openSSH", () => Promise.reject(new Error("openSSH is unavailable"))),
    revokeSSHIdentity: () => Effect.void,
  };
}

function layerFor(gateway: VmProviderGatewayShape) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, gateway),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

function createInput(userId: string, local: ProviderCredential) {
  return {
    userId,
    billingTeamId: `team-${userId}`,
    billingCustomerType: "team" as const,
    billingPlanId: "pro",
    maxActiveVms: 2,
    provider: "gcp" as const,
    image: `projects/${PROJECT}/global/images/cmux-linux`,
    idempotencyKey: `create-${userId}`,
    providerMetadata: { project: PROJECT, zone: ZONE },
    providerCredential: local,
  };
}

async function createRow(userId: string) {
  const [row] = await sql!<{ status: string; failureCode: string | null; providerVmId: string | null; metadata: Record<string, unknown> }[]>`
    select status, failure_code as "failureCode", provider_vm_id as "providerVmId", provider_metadata as metadata
    from cloud_vms where user_id = ${userId}
  `;
  return row;
}

async function insertRunningGcpRow(userId: string, providerVmId: string) {
  await sql!`
    insert into cloud_vms (user_id, owner_team_id, billing_team_id, billing_plan_id, provider, image_id, status, provider_vm_id, provider_metadata)
    values (${userId}, ${`team-${userId}`}, ${`team-${userId}`}, 'pro', 'gcp', 'cmux-linux', 'running', ${providerVmId}, '{}'::jsonb)
  `;
}

/** Waits for Compute Engine to accept the insert; a create that ends first fails the test. */
async function untilInserted(gcp: ReturnType<typeof computeEngine>, create: Promise<unknown>) {
  await Promise.race([
    gcp.insertAccepted,
    create.then((result) => { throw new Error(`create ended before its insert: ${JSON.stringify(result)}`); }),
  ]);
}

const later = () => Date.now() + VM_CREATE_ABANDONED_AFTER_MS + 60_000;

describe("GCP create cleanup without a stored credential", () => {
  dbTest("a create interrupted after the insert, its credential wiped, is deleted by the owner's next credentialed request", async () => {
    const gcp = computeEngine();
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn })));
    const userId = "user-gcp-interrupted";
    const local = credential("create-token");

    const fiber = Effect.runFork(createVm(createInput(userId, local)).pipe(Effect.provide(layer)));
    await untilInserted(gcp, Effect.runPromise(Fiber.await(fiber)));
    // The process stops mid-create: no failure handler runs, and the
    // workflow's finalizer wipes the token (aborting the in-flight poll).
    await Effect.runPromise(Fiber.interrupt(fiber));
    expect(local.accessToken.wiped).toBe(true);
    expect(gcp.instances.size).toBe(1);
    const [instanceName] = [...gcp.instances];
    const providerVmId = `${PROJECT}/${ZONE}/${instanceName}`;
    // The row named the instance before Compute Engine was asked for it.
    expect(await createRow(userId)).toMatchObject({
      status: "provisioning",
      failureCode: null,
      providerVmId: null,
      metadata: { createCleanupProviderVmId: providerVmId },
    });

    // The background cron has no credential: it retains the delete instead of
    // abandoning the row, and sends Compute Engine nothing.
    const sentBeforeCron = gcp.sent.length;
    await Effect.runPromise(reconcileVmProviderStatuses({ now: later }).pipe(Effect.provide(layer)));
    expect(gcp.sent.length).toBe(sentBeforeCron);
    expect(await createRow(userId)).toMatchObject({
      status: "provisioning",
      failureCode: "provider_create_cleanup_pending",
      metadata: { createCleanupProviderVmId: providerVmId },
    });
    expect(gcp.instances.has(instanceName!)).toBe(true);

    // Any later request carrying the user's credential deletes it, even one
    // that fails for its own reasons.
    const next = credential("next-request-token");
    const read = await Effect.runPromise(Effect.either(getVm({
      userId,
      providerVmId: `${PROJECT}/${ZONE}/some-other-machine`,
      providerCredential: next,
    }).pipe(Effect.provide(layer))));
    expect(read._tag).toBe("Left");
    expect(gcp.instances.size).toBe(0);
    expect(gcp.sent.filter((call) => call.method === "DELETE")).toEqual([{
      method: "DELETE",
      path: `/projects/${PROJECT}/zones/${ZONE}/instances/${instanceName}`,
      token: "Bearer next-request-token",
    }]);
    expect(next.accessToken.wiped).toBe(true);
    const resolved = await createRow(userId);
    expect(resolved.status).toBe("failed");
    expect(resolved.metadata.createCleanupProviderVmId).toBeUndefined();
  });

  dbTest("a create whose rollback lost its credential keeps the row as a retained cleanup until account deletion's drain", async () => {
    const gcp = computeEngine();
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn })));
    const userId = "user-gcp-wiped";
    const local = credential("create-token");

    const creating = Effect.runPromise(Effect.either(createVm(createInput(userId, local)).pipe(Effect.provide(layer))));
    await untilInserted(gcp, creating);
    wipeProviderCredential(local);
    const result = await creating;
    expect(result._tag).toBe("Left");
    const [instanceName] = [...gcp.instances];
    expect(await createRow(userId)).toMatchObject({
      status: "provisioning",
      failureCode: "provider_create_cleanup_pending",
      metadata: { createCleanupProviderVmId: `${PROJECT}/${ZONE}/${instanceName}` },
    });

    // The Freestyle cleanup worker never takes a credential-bound row.
    await Effect.runPromise(reconcileVmProviderStatuses({ now: later }).pipe(Effect.provide(layer)));
    expect(gcp.instances.has(instanceName!)).toBe(true);

    await Effect.runPromise(drainProviderCreateCleanups({
      userId,
      providerCredential: credential("account-deletion-token"),
    }).pipe(Effect.provide(layer)));
    expect(gcp.instances.size).toBe(0);
    expect((await createRow(userId)).status).toBe("failed");
  });

  dbTest("a not-found delete resolves a retained create only after its insert can no longer land", async () => {
    const gcp = computeEngine();
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn })));
    const userId = "user-gcp-settle";
    const metadata = (intentAtMs: number) => sql!.json({
      createCleanupProviderVmId: `${PROJECT}/${ZONE}/cmux-never-seen`,
      createCleanupIntentAtMs: intentAtMs,
      createCleanupAttempt: 0,
      createCleanupNextAttemptAtMs: 0,
    });
    await sql!`
      insert into cloud_vms (user_id, owner_team_id, billing_team_id, billing_plan_id, provider, image_id, status, failure_code, provider_metadata)
      values (${userId}, ${`team-${userId}`}, ${`team-${userId}`}, 'pro', 'gcp', 'cmux-linux', 'provisioning',
        'provider_create_cleanup_pending', ${metadata(Date.now())})
    `;
    const drain = () => Effect.runPromise(drainProviderCreateCleanups({
      userId,
      providerCredential: credential("drain-token"),
    }).pipe(Effect.provide(layer)));

    await drain();
    expect(gcp.sent.map((call) => call.method)).toEqual(["DELETE"]);
    expect((await createRow(userId)).failureCode).toBe("provider_create_cleanup_pending");

    await sql!`update cloud_vms set provider_metadata = ${metadata(Date.now() - VM_CREATE_ABANDONED_AFTER_MS - 1)} where user_id = ${userId}`;
    await drain();
    expect((await createRow(userId)).status).toBe("failed");
  });

  dbTest("the status cron leaves a GCP machine alone without a credential", async () => {
    const gcp = computeEngine();
    const calls: string[] = [];
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn }), calls));
    await insertRunningGcpRow("user-gcp-cron", `${PROJECT}/${ZONE}/cmux-running`);

    await Effect.runPromise(reconcileVmProviderStatuses().pipe(Effect.provide(layer)));

    expect(calls).toContain("getStatus");
    expect(gcp.sent).toEqual([]);
    expect(await createRow("user-gcp-cron")).toMatchObject({ status: "running", providerVmId: `${PROJECT}/${ZONE}/cmux-running` });
  });

  dbTest("idle pause never probes or pauses a GCP machine (the guest stops itself)", async () => {
    const gcp = computeEngine();
    const calls: string[] = [];
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn }), calls));
    await insertRunningGcpRow("user-gcp-idle", `${PROJECT}/${ZONE}/cmux-idle`);

    await Effect.runPromise(enforceVmIdlePause().pipe(Effect.provide(layer)));

    expect(calls).toEqual([]);
    expect((await createRow("user-gcp-idle")).status).toBe("running");
  });

  dbTest("account deletion's destroy fails closed without a credential and deletes with one", async () => {
    const gcp = computeEngine();
    const layer = layerFor(gcpGateway(new GcpProvider({ fetch: gcp.fetch, env: labsOn })));
    const userId = "user-gcp-account";
    const providerVmId = `${PROJECT}/${ZONE}/cmux-owned`;
    gcp.instances.add("cmux-owned");
    await insertRunningGcpRow(userId, providerVmId);
    const destroy = (providerCredential?: ProviderCredential) => Effect.runPromise(Effect.either(destroyVm({
      userId,
      billingTeamId: `team-${userId}`,
      teamIds: [`team-${userId}`],
      providerVmId,
      provider: "gcp",
      source: "account_deletion",
      providerCredential,
    }).pipe(Effect.provide(layer))));

    expect((await destroy())._tag).toBe("Left");
    expect(gcp.sent).toEqual([]);
    expect((await createRow(userId)).status).toBe("running");

    expect((await destroy(credential("account-deletion-token")))._tag).toBe("Right");
    expect(gcp.instances.size).toBe(0);
    expect((await createRow(userId)).status).toBe("destroyed");
  });
});
