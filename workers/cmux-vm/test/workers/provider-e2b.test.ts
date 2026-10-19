import { describe, expect, it } from "vitest";
import { name } from "@gdp-ts/core";
import { Effect, Layer, Option, Redacted } from "effect";
import { OwnershipStore, type OwnedResource } from "../../src/db/stores.ts";
import { ApiKeyId, TenantId, newSnapshotId, newVmId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import type { Principal } from "../../src/domain/principal.ts";
import type { Scope } from "../../src/domain/scopes.ts";
import { keyHasScope } from "../../src/proofs/key-has-scope.ts";
import { Entitlements, tenantMayCreate } from "../../src/proofs/tenant-may-create.ts";
import { tenantOwnsSnapshot, tenantOwnsVm } from "../../src/proofs/tenant-owns-resource.ts";
import { E2B_CAPABILITIES } from "../../src/providers/e2b/capabilities.ts";
import { makeE2bUpstreamClient } from "../../src/upstream/live-e2b.ts";
import { makeFakeE2b } from "../support/fake-e2b.ts";

const tenant = TenantId.make("team_e2b");
const principal: Principal = {
  tenantId: tenant,
  actor: { kind: "api_key", keyId: ApiKeyId.make("vmk_00000000000000000000000000") },
  scopes: new Set<Scope>(["vm:read", "vm:write", "vm:exec", "vm:files"]),
  resourceAllowlist: null,
  credentialExpiresAt: null,
};

const makeOwnership = (rows: OwnedResource[]) =>
  Layer.succeed(OwnershipStore, {
    find: (tenantId, kind, cmuxId) => Effect.succeed(Option.fromNullable(rows.find((row) => row.tenantId === tenantId && row.kind === kind && row.cmuxId === cmuxId))),
    record: (row) => Effect.sync(() => rows.push(row)),
    listPage: () => Effect.succeed(rows),
    countLive: () => Effect.succeed(0),
    markDeleted: () => Effect.void,
  });

const makeServices = (rows: OwnedResource[]) =>
  Layer.mergeAll(
    makeOwnership(rows),
    memoryLimitsLayer(),
    tenantPolicyLayer({ environment: "local" }),
    Layer.succeed(Entitlements, { mayCreate: () => Effect.succeed(true) }),
  );

const streamOf = (bytes: Uint8Array) =>
  new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bytes);
      controller.close();
    },
  });

describe("E2B provider adapter", () => {
  it("requires the platform API key in the fake", async () => {
    const fake = makeFakeE2b();
    const response = await fake.fetch(new Request("https://api.test/v2/sandboxes", { method: "POST", body: JSON.stringify({ templateID: "node-22" }) }));
    expect(response.status).toBe(401);
  });

  it("drives every upstream method through minted proofs", async () => {
    const fake = makeFakeE2b();
    const client = makeE2bUpstreamClient({
      apiKey: Redacted.make("e2b-test-key"),
      apiUrl: "https://api.test/",
      domain: "https://sandbox.test/",
      fetch: fake.fetch,
      environment: "test",
      templateId: "node-22",
    });
    const vmId = newVmId();
    const snapshotPublicId = newSnapshotId();
    const rows: OwnedResource[] = [];
    const services = makeServices(rows);
    const result = await Effect.runPromise(
      Effect.provide(
        name(principal, vmId, snapshotPublicId, (caller, vm, snapshot) =>
          Effect.gen(function* () {
            const read = keyHasScope(caller, "vm:read");
            const write = keyHasScope(caller, "vm:write");
            const exec = keyHasScope(caller, "vm:exec");
            const files = keyHasScope(caller, "vm:files");
            if (read === null || write === null || exec === null || files === null) throw new Error("test scope setup failed");
            const decision = yield* tenantMayCreate(caller, "vm");
            if (decision._tag !== "granted") throw new Error("test quota setup failed");
            const refusedOptions = yield* client.createVm(caller, { cmuxId: vmId, idleTimeoutSeconds: 60, maxRunSeconds: 10, environment: "test" }, { mayCreate: decision.proof, scope: write }).pipe(Effect.flip);
            const refusedZero = yield* client.createVm(caller, { cmuxId: vmId, idleTimeoutSeconds: 0, environment: "test" }, { mayCreate: decision.proof, scope: write }).pipe(Effect.flip);
            const created = yield* client.createVm(caller, { cmuxId: vmId, idleTimeoutSeconds: 60, environment: "test", size: { vcpus: 2, memoryMib: 512, diskMib: 10240 } }, { mayCreate: decision.proof, scope: write });
            rows.push({ tenantId: tenant, kind: "vm", cmuxId: vmId, upstreamId: created.upstreamId, createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
            const owns = yield* tenantOwnsVm(caller, vm);
            if (owns === null) throw new Error("test ownership setup failed");
            const current = yield* client.getVm(vm, { owns, scope: read });
            const currentForWrite = yield* client.getVmForWrite(vm, { owns, scope: write });
            const execBody = yield* client.exec(vm, { owns, scope: exec }, { command: "echo ok", stdinBase64: "aGk=" });
            const execText = yield* Effect.promise(() => new Response(execBody).text());
            yield* client.writeFile(vm, { owns, scope: files }, { path: "/tmp/hello.txt", mode: undefined, body: streamOf(new TextEncoder().encode("written")), length: 7 });
            const file = yield* client.readFile(vm, { owns, scope: files }, "/tmp/hello.txt", undefined);
            const fileText = yield* Effect.promise(() => new Response(file.body).text());
            const listed = yield* client.listFiles(vm, { owns, scope: files }, "/tmp");
            const paused = yield* client.pauseVm(vm, { owns, scope: write });
            const resumed = yield* client.startVm(vm, { owns, scope: write });
            const shutdown = yield* client.shutdownVm(vm, { owns, scope: write }).pipe(Effect.flip);
            const fork = yield* client.snapshotForFork(caller, vm, { cmuxId: snapshotPublicId }, { owns, scope: write, mayCreate: decision.proof });
            rows.push({ tenantId: tenant, kind: "snapshot", cmuxId: snapshotPublicId, upstreamId: fork.upstreamId, createdBy: "test", createdAt: new Date(), displayName: null, labels: {} });
            const ownsSnapshot = yield* tenantOwnsSnapshot(caller, snapshot);
            if (ownsSnapshot === null) throw new Error("test snapshot ownership setup failed");
            const deletedSnapshot = yield* client.deleteSnapshot(snapshot, { owns: ownsSnapshot, scope: write });
            const deletedVm = yield* client.deleteVm(vm, { owns, scope: write });
            const refusedResize = yield* created.grow({ vcpus: 4 }).pipe(Effect.flip);
            return { current, currentForWrite, execText, fileText, listed, paused, resumed, shutdown, deletedSnapshot, deletedVm, refusedResize, refusedOptions, refusedZero };
          }),
        ),
        services,
      ),
    );

    expect(result.current.state).toBe("running");
    expect(result.current.resources).toEqual({ cpu: 2, memory: 512, storage: 10240 });
    expect(result.currentForWrite.state).toBe("running");
    expect(result.refusedOptions).toMatchObject({ _tag: "UpstreamError", status: 409 });
    expect(result.refusedZero).toMatchObject({ _tag: "UpstreamError", status: 422 });
    expect(JSON.parse(result.execText)).toEqual({ exitCode: 0, stdout: "ok\n", stderr: "" });
    expect(result.fileText).toBe("written");
    expect(result.listed).toEqual([{ name: "hello.txt", kind: "file" }]);
    expect(result.paused.state).toBe("paused");
    expect(result.resumed.state).toBe("running");
    expect(result.shutdown).toMatchObject({ _tag: "UpstreamError", status: 409 });
    expect(result.deletedSnapshot).toBe("deleted");
    expect(result.deletedVm).toBe("deleted");
    expect(result.refusedResize).toMatchObject({ _tag: "UpstreamError", status: 409 });
    expect(fake.calls.some((call) => call.url.endsWith("/process.Process/Start") && call.headers.get("x-access-token") === "envd-sbx-1")).toBe(true);
    expect(fake.calls.some((call) => call.url.endsWith("/process.Process/SendInput") && new TextDecoder().decode(call.body ?? new Uint8Array()).includes("aGk=")).toBe(true);
    expect(fake.calls.some((call) => call.url.endsWith("/v2/sandboxes/sbx-1/connect") && new TextDecoder().decode(call.body ?? new Uint8Array()).includes('"timeout":60'))).toBe(true);
    expect(fake.calls.some((call) => call.url.endsWith("/v2/sandboxes") && call.headers.get("x-api-key") === "e2b-test-key")).toBe(true);
  });

  it("preserves provider HTTP statuses as UpstreamError", async () => {
    const fake = makeFakeE2b();
    fake.fail("POST", "/v2/sandboxes", 429);
    const client = makeE2bUpstreamClient({ apiKey: Redacted.make("e2b-test-key"), apiUrl: "https://api.test/", fetch: fake.fetch, environment: "test" });
    const services = makeServices([]);
    const result = await Effect.runPromise(
      Effect.either(
        Effect.provide(
          name(principal, newVmId(), (caller, vm) =>
            Effect.gen(function* () {
              const scope = keyHasScope(caller, "vm:write");
              if (scope === null) throw new Error("test scope setup failed");
              const decision = yield* tenantMayCreate(caller, "vm");
              if (decision._tag !== "granted") throw new Error("test quota setup failed");
              return yield* client.createVm(caller, { cmuxId: vm.value, idleTimeoutSeconds: 60, environment: "test" }, { mayCreate: decision.proof, scope });
            }),
          ),
          services,
        ),
      ),
    );
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") expect(result.left).toMatchObject({ _tag: "UpstreamError", status: 429 });
  });

  it("publishes explicit refusals for capabilities E2B does not provide", () => {
    expect(E2B_CAPABILITIES.stop).toBe("none");
    expect(E2B_CAPABILITIES.fork).toBe("snapshot-create");
    expect(E2B_CAPABILITIES.lifecycleEvents).toBe("reconcile");
    expect(E2B_CAPABILITIES.resize).toBe("none");
    expect(E2B_CAPABILITIES.delegatedAccess).toBe(false);
    expect(E2B_CAPABILITIES.ssh).toBe("websocket-proxy");
  });
});
