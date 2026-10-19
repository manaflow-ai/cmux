import { name, type Named } from "@gdp-ts/core";
import { describe, expect, it } from "vitest";
import { Effect, Layer, Redacted, Option } from "effect";
import { signWebhookContent } from "../../src/auth/webhook-signature.ts";
import { OwnershipStore, type OwnedResource } from "../../src/db/stores.ts";
import { type Principal } from "../../src/domain/principal.ts";
import { TenantId, newSnapshotId, newVmId, UpstreamId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { Entitlements, tenantMayCreate } from "../../src/proofs/tenant-may-create.ts";
import { keyHasScope, type KeyHasScope } from "../../src/proofs/key-has-scope.ts";
import type { Scope } from "../../src/domain/scopes.ts";
import { tenantOwnsSnapshot, tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { makeDaytonaUpstreamClient } from "../../src/providers/daytona/live.ts";
import { DAYTONA_CAPABILITIES } from "../../src/providers/capabilities.ts";
import { makeDaytonaWebhookHandler } from "../../src/providers/daytona/webhook.ts";
import type { UsageEvent } from "../../src/metering/recorder.ts";
import { makeFakeDaytona } from "../support/fake-daytona.ts";

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect);

const scopeOf = <C, const S extends Scope>(caller: Named<C, Principal>, scope: S): Effect.Effect<KeyHasScope<C, S>> => {
  const proof = keyHasScope(caller, scope);
  return proof === null ? Effect.die("test scope proof missing") : Effect.succeed(proof);
};

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
  return { ownership, runtime, resources };
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
    await run(
      name(principal, (caller) =>
        Effect.gen(function* () {
          const decision = yield* tenantMayCreate(caller, "vm").pipe(Effect.provide(proofs.runtime));
          if (decision._tag !== "granted") return yield* Effect.die("test create proof missing");
          const write = yield* scopeOf(caller, "vm:write");
          const create = yield* client.createVm(caller, { cmuxId: vmId, idleTimeoutSeconds: 120, environment: "test", size: { vcpus: 2, memoryMib: 4096, diskMib: 8192 } }, { mayCreate: decision.proof, scope: write });
          proofs.resources.push({ tenantId: tenant, kind: "vm", cmuxId: vmId, upstreamId: create.upstreamId, createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
          expect(create.vm).toMatchObject({ state: "running", resources: { cpu: 2, memory: 4096, storage: 8192 }, idleTimeoutSeconds: 120 });
          return yield* name(vmId, (vm) =>
            Effect.gen(function* () {
              const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.provide(proofs.ownership));
              if (owns === null) return yield* Effect.die("test VM ownership proof missing");
              const read = yield* scopeOf(caller, "vm:read");
              const exec = yield* scopeOf(caller, "vm:exec");
              const files = yield* scopeOf(caller, "vm:files");
              expect((yield* client.getVm(vm, { owns, scope: read })).state).toBe("running");
              expect((yield* client.getVmForWrite(vm, { owns, scope: write })).resources.memory).toBe(4096);
              const output = yield* client.exec(vm, { owns, scope: exec }, { command: "echo ok" });
              const outputText = yield* Effect.promise(() => new Response(output).text());
              expect(JSON.parse(outputText)).toEqual({ exitCode: 0, stdout: "ran: echo ok\n", stderr: "" });
              const content = new TextEncoder().encode("hello daytona");
              yield* client.writeFile(vm, { owns, scope: files }, { path: "workspace/hello.txt", mode: 0o644, body: new ReadableStream({ start(controller) { controller.enqueue(content); controller.close(); } }), length: content.length });
              const file = yield* client.readFile(vm, { owns, scope: files }, "workspace/hello.txt", undefined);
              const fileText = yield* Effect.promise(() => new Response(file.body).text());
              expect(fileText).toBe("hello daytona");
              expect(yield* client.listFiles(vm, { owns, scope: files }, "workspace")).toEqual([{ name: "hello.txt", kind: "file" }]);
              const grown = yield* create.grow({ vcpus: 3, memoryMib: 5120, diskMib: 9216 });
              expect(grown.resources).toEqual({ cpu: 3, memory: 5120, storage: 9216 });
              const snapshotCmuxId = newSnapshotId();
              const snapshot = yield* client.snapshotForFork(caller, vm, { cmuxId: snapshotCmuxId }, { owns, scope: write, mayCreate: decision.proof });
              proofs.resources.push({ tenantId: tenant, kind: "snapshot", cmuxId: snapshotCmuxId, upstreamId: snapshot.upstreamId, createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
              return yield* name(snapshotCmuxId, (snapshotNamed) =>
                Effect.gen(function* () {
                  const snapshotOwns = yield* tenantOwnsSnapshot(caller, snapshotNamed).pipe(Effect.provide(proofs.ownership));
                  if (snapshotOwns === null) return yield* Effect.die("test snapshot ownership proof missing");
                  expect(yield* client.deleteSnapshot(snapshotNamed, { owns: snapshotOwns, scope: write })).toBe("deleted");
                  expect((yield* client.pauseVm(vm, { owns, scope: write })).state).toBe("stopped");
                  expect((yield* client.startVm(vm, { owns, scope: write })).state).toBe("running");
                  yield* client.shutdownVm(vm, { owns, scope: write });
                  expect(yield* client.deleteVm(vm, { owns, scope: write })).toBe("deleted");
                }),
              );
            }),
          );
        }),
      ),
    );
    expect(fake.calls.some((call) => call.url.pathname.endsWith("/sandbox") && call.method === "POST")).toBe(true);
    expect(fake.calls.find((call) => call.method === "POST" && call.url.pathname.endsWith("/sandbox"))?.url.pathname).toBe("/api/sandbox");
  });

  it("maps provider failures to UpstreamError without leaking response bodies", async () => {
    const fake = makeFakeDaytona();
    const client = makeDaytonaUpstreamClient({ apiKey: Redacted.make("daytona-test-key"), apiUrl: "https://daytona.test/api", environment: "test", fetch: fake.fetch });
    const proofs = await makeProofs();
    const vmId = newVmId();
    proofs.resources.push({ tenantId: tenant, kind: "vm", cmuxId: vmId, upstreamId: UpstreamId.make("missing-sandbox"), createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
    const result = await run(
      Effect.either(
        name(principal, (caller) =>
          name(vmId, (vm) =>
            Effect.gen(function* () {
              const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.provide(proofs.ownership));
              if (owns === null) return yield* Effect.die("test ownership proof missing");
              const read = yield* scopeOf(caller, "vm:read");
              return yield* client.getVm(vm, { owns, scope: read });
            }),
          ),
        ),
      ),
    );
    expect(result._tag).toBe("Left");
    if (result._tag === "Left" && result.left._tag === "UpstreamError") expect(result.left.status).toBe(404);
    else expect.fail("expected Daytona UpstreamError");
  });

  it("reports the capability boundaries of the Daytona default sandbox", () => {
    expect(DAYTONA_CAPABILITIES.pauseWithMemory).toBe(false);
    expect(DAYTONA_CAPABILITIES.egressControl).toBe("allow-deny-list");
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
