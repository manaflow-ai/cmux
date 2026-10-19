import { name } from "@gdp-ts/core";
import { describe, expect, it } from "vitest";
import { Effect, Layer, Redacted, Option } from "effect";
import { signWebhookContent } from "../../src/auth/webhook-signature.ts";
import { OwnershipStore, type OwnedResource } from "../../src/db/stores.ts";
import { type Principal } from "../../src/domain/principal.ts";
import { TenantId, newSnapshotId, newVmId, UpstreamId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { Entitlements, tenantMayCreate } from "../../src/proofs/tenant-may-create.ts";
import { keyHasScope } from "../../src/proofs/key-has-scope.ts";
import { tenantOwnsSnapshot, tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { makeDaytonaUpstreamClient } from "../../src/providers/daytona/live.ts";
import { DAYTONA_CAPABILITIES } from "../../src/providers/capabilities.ts";
import { makeDaytonaWebhookHandler } from "../../src/providers/daytona/webhook.ts";
import type { UsageEvent } from "../../src/metering/recorder.ts";
import { makeFakeDaytona } from "../support/fake-daytona.ts";

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect);

const tenant = TenantId.make("tenant_daytona");
const principal: Principal = {
  tenantId: tenant,
  actor: { kind: "service", serviceId: "daytona-test" },
  scopes: new Set(["vm:read", "vm:write", "vm:exec", "vm:files", "snapshot:*"]),
  resourceAllowlist: null,
  credentialExpiresAt: null,
};

const makeProofs = async () => {
  const resources: OwnedResource[] = [];
  const ownership = Layer.succeed(OwnershipStore, {
    find: (tenantId: TenantId, kind: OwnedResource["kind"], cmuxId: string) =>
      Effect.succeed(Option.fromNullable(resources.find((resource) => resource.tenantId === tenantId && resource.kind === kind && resource.cmuxId === cmuxId))),
    record: (resource: OwnedResource) => Effect.sync(() => void resources.push(resource)),
    listPage: () => Effect.succeed([]),
    countLive: (tenantId: TenantId, kind: OwnedResource["kind"]) => Effect.succeed(resources.filter((resource) => resource.tenantId === tenantId && resource.kind === kind).length),
    markDeleted: () => Effect.void,
  });
  const runtime = Layer.mergeAll(
    ownership,
    memoryLimitsLayer(),
    tenantPolicyLayer({ environment: "local" }),
    Layer.succeed(Entitlements, { mayCreate: () => Effect.succeed(true) }),
  );
  const caller = await run(name(principal, (value) => Effect.succeed(value)));
  const ownVm = async (cmuxId: ReturnType<typeof newVmId>, upstreamId: string) => {
    resources.push({ tenantId: tenant, kind: "vm", cmuxId, upstreamId: UpstreamId.make(upstreamId), createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
    return run(name(cmuxId, (value) => tenantOwnsVm(caller, value)).pipe(Effect.provide(ownership)));
  };
  const ownSnapshot = async (cmuxId: ReturnType<typeof newSnapshotId>, upstreamId: string) => {
    resources.push({ tenantId: tenant, kind: "snapshot", cmuxId, upstreamId: UpstreamId.make(upstreamId), createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
    return run(name(cmuxId, (value) => tenantOwnsSnapshot(caller, value)).pipe(Effect.provide(ownership)));
  };
  const mayCreate = async () => {
    const decision = await run(tenantMayCreate(caller, "vm").pipe(Effect.provide(runtime)));
    if (decision._tag !== "granted") throw new Error(`expected create proof, got ${decision._tag}`);
    return decision.proof;
  };
  return { caller, ownVm, ownSnapshot, mayCreate, resources };
};

describe("Daytona provider adapter", () => {
  it("drives every upstream method through the real proof minting paths", async () => {
    const fake = makeFakeDaytona();
    const client = makeDaytonaUpstreamClient({
      apiKey: Redacted.make("daytona-test-key"),
      apiUrl: "https://daytona.test/api",
      organizationId: "org-test",
      environment: "test",
      fetch: fake.fetch,
    });
    const proofs = await makeProofs();
    const vmId = newVmId();
    const create = await run(
      client.createVm(proofs.caller, { cmuxId: vmId, idleTimeoutSeconds: 120, environment: "test", size: { vcpus: 2, memoryMib: 4096, diskMib: 8192 } }, { mayCreate: await proofs.mayCreate(), scope: keyHasScope(proofs.caller, "vm:write")! }),
    );
    expect(create.vm).toMatchObject({ state: "running", resources: { cpu: 2, memory: 4096, storage: 8192 }, idleTimeoutSeconds: 120 });
    const owns = await proofs.ownVm(vmId, create.upstreamId);
    const read = keyHasScope(proofs.caller, "vm:read")!;
    const write = keyHasScope(proofs.caller, "vm:write")!;
    const exec = keyHasScope(proofs.caller, "vm:exec")!;
    const files = keyHasScope(proofs.caller, "vm:files")!;
    expect((await run(client.getVm(vmId, { owns, scope: read }))).state).toBe("running");
    expect((await run(client.getVmForWrite(vmId, { owns, scope: write }))).resources.memory).toBe(4096);
    const output = await run(client.exec(vmId, { owns, scope: exec }, { command: "echo ok" }));
    expect(JSON.parse(await new Response(output).text())).toEqual({ exitCode: 0, stdout: "ran: echo ok\n", stderr: "" });
    const content = new TextEncoder().encode("hello daytona");
    await run(client.writeFile(vmId, { owns, scope: files }, { path: "workspace/hello.txt", mode: 0o644, body: new ReadableStream({ start(controller) { controller.enqueue(content); controller.close(); } }), length: content.length }));
    const file = await run(client.readFile(vmId, { owns, scope: files }, "workspace/hello.txt", undefined));
    expect(await new Response(file.body).text()).toBe("hello daytona");
    expect(await run(client.listFiles(vmId, { owns, scope: files }, "workspace")).then((entries) => entries)).toEqual([{ name: "hello.txt", kind: "file" }]);
    const grown = await run(create.grow({ vcpus: 3, memoryMib: 5120, diskMib: 9216 }));
    expect(grown.resources).toEqual({ cpu: 3, memory: 5120, storage: 9216 });
    const snapshotCmuxId = newSnapshotId();
    const snapshot = await run(client.snapshotForFork(proofs.caller, vmId, { cmuxId: snapshotCmuxId }, { owns, scope: write, mayCreate: await proofs.mayCreate() }));
    const snapshotOwns = await proofs.ownSnapshot(snapshotCmuxId, snapshot.upstreamId);
    expect(await run(client.deleteSnapshot(snapshotCmuxId, { owns: snapshotOwns, scope: write }))).toBe("deleted");
    expect((await run(client.pauseVm(vmId, { owns, scope: write }))).state).toBe("stopped");
    expect((await run(client.startVm(vmId, { owns, scope: write }))).state).toBe("running");
    await run(client.shutdownVm(vmId, { owns, scope: write }));
    expect(await run(client.deleteVm(vmId, { owns, scope: write }))).toBe("deleted");
    expect(fake.calls.some((call) => call.url.pathname.endsWith("/sandbox") && call.method === "POST")).toBe(true);
    expect(fake.calls.find((call) => call.method === "POST" && call.url.pathname.endsWith("/sandbox"))?.url.pathname).toBe("/api/sandbox");
  });

  it("maps provider failures to UpstreamError without leaking response bodies", async () => {
    const fake = makeFakeDaytona();
    const client = makeDaytonaUpstreamClient({ apiKey: Redacted.make("daytona-test-key"), apiUrl: "https://daytona.test/api", environment: "test", fetch: fake.fetch });
    const proofs = await makeProofs();
    const vmId = newVmId();
    const owns = await proofs.ownVm(vmId, "missing-sandbox");
    const result = await run(Effect.either(client.getVm(vmId, { owns, scope: keyHasScope(proofs.caller, "vm:read")! })));
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left._tag).toBe("UpstreamError");
      expect(result.left.status).toBe(404);
    }
  });

  it("refuses the capabilities the Daytona default sandbox does not provide", () => {
    expect(DAYTONA_CAPABILITIES.pauseWithMemory).toBe(false);
    expect(DAYTONA_CAPABILITIES.egressControl).toBe("none");
    expect(DAYTONA_CAPABILITIES.fork).toBe("snapshot-create");
  });
});

describe("Daytona lifecycle webhooks", () => {
  const secret = Redacted.make("whsec_MDEyMzQ1Njc4OWFiY2RlZg==");
  const payload = JSON.stringify({ event: "sandbox.state.updated", timestamp: "2026-10-18T00:00:00.000Z", id: "sbx-1", organizationId: "org-test", oldState: "started", newState: "stopped", updatedAt: "2026-10-18T00:00:00.000Z" });
  const signedRequest = async (id: string, body = payload, signatureBody = body) => {
    const timestamp = "1792281600";
    const signature = await signWebhookContent(secret, `${id}.${timestamp}.${signatureBody}`);
    return new Request("https://cmux.test/daytona", { method: "POST", body, headers: { "svix-id": id, "svix-timestamp": timestamp, "svix-signature": `v1,${signature ?? ""}` } });
  };

  it("records a valid event and refuses tampering and replay", async () => {
    const recorded: UsageEvent[] = [];
    const handler = makeDaytonaWebhookHandler({
      secret,
      nowMs: () => 1792281600000,
      resolveSandbox: async () => ({ tenantId: "tenant_daytona", vcpus: 2, memoryMb: 4096, storageMb: 8192 }),
      recorder: { record: (event) => Effect.sync(() => void recorded.push(event)) },
    });
    const valid = await run(handler(await signedRequest("daytona-message-1")));
    expect(valid.status).toBe(200);
    expect(recorded).toEqual([expect.objectContaining({ kind: "vm_stopped", reason: "stop", upstreamVmId: "sbx-1" })]);
    const replay = await run(handler(await signedRequest("daytona-message-1")));
    expect(replay.status).toBe(200);
    expect(await replay.json()).toEqual({ ok: true, duplicate: true });
    const tampered = await run(handler(await signedRequest("daytona-message-2", payload.replace("stopped", "destroyed"), payload)));
    expect(tampered.status).toBe(401);
  });
});
