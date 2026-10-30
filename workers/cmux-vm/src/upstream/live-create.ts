/** Recovery is confined to an intent's exact unique slug, authorized by its retained create proof. */
import { Effect, Option, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { vmImageEvidenceOf } from "../proofs/vm-image.ts";
import { initialNetworkBody } from "./initial-network.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import { resourceFloorsReached, UpstreamError, UpstreamVm, type SizeRequest, type UpstreamClientService } from "./client.ts";
import type { UpstreamConfig } from "./live.ts";
import { pendingVmCreationEvidenceOf, cancellingVmCreationEvidenceOf, type VmCreationEvidence } from "../proofs/vm-creation.ts";
import { upstreamName } from "./naming.ts";

const Receipt = Schema.Struct({ id: UpstreamId, ...UpstreamVm.fields, slug: Schema.String, metadata: Schema.Record({ key: Schema.String, value: Schema.String }), snapshotId: Schema.optional(Schema.NullOr(Schema.String)) });
const digest = (text: string) => Effect.promise(async () => {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
});

/** The provider's own customer id rule (freestyle@0.2.21 `Customer.customerId`). */
const CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/u;

/** 4xx answers that prove the provider made nothing; 408 (timeout), 409 (slug may exist), 5xx and transport errors do not. */
const definitelyRejected = (status: number | null) => status !== null && status >= 400 && status < 500 && status !== 408 && status !== 409;

export const makeDurableCreate = (config: UpstreamConfig, baseImageFor: (size: SizeRequest | undefined) => string | null): UpstreamClientService["createVm"] => {
  const http = makeUpstreamHttp(config);
  const decode = (body: unknown) => Schema.decodeUnknown(Receipt)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "createVm", status: null })));
  return (caller, spec, { source, image, network }) => Effect.gen(function* () {
    const journal = spec.journal;
    if (!journal) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: null }));
    const sourceId = source === undefined ? null : upstreamIdOf(source.owns);
    const imageId = image === undefined ? null : vmImageEvidenceOf(image).snapshotId;
    if (sourceId !== null && imageId !== null) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
    const slug = `cmux-vm-${config.environment}-${spec.cmuxId.replace("_", "-")}`;
    const metadata: Record<string, string> = { cmux_id: spec.cmuxId, cmux_env: spec.environment };
    if (spec.createdBy !== undefined && spec.createdBy.length <= 63) metadata["cmux_actor"] = spec.createdBy;
    if (caller.value.tenantId.length <= 63) metadata["cmux_tenant"] = caller.value.tenantId;
    const body = {
      slug, displayName: upstreamName(config.environment, caller.value.tenantId, spec.cmuxId), metadata,
      idleTimeoutSeconds: spec.idleTimeoutSeconds,
      ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
      ...(spec.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: spec.autoDeleteSeconds }),
      ...initialNetworkBody(network),
      ...((sourceId ?? imageId ?? baseImageFor(spec.size)) === null ? {} : { snapshotId: sourceId ?? imageId ?? baseImageFor(spec.size) }),
    };
    const request = yield* digest(JSON.stringify(body));
    metadata["cmux_create"] = request;
    const context = yield* digest(JSON.stringify([config.baseUrl, Redacted.value(config.apiKey), body]));
    // The tenant is the provider's customer (abuse protection tells tenants apart by it). It is sent outside the
    // digests above: it follows from the tenant id the name and metadata already carry, and a create journaled
    // before this field existed must still match its retained request and context.
    const sent = CUSTOMER_ID.test(caller.value.tenantId) ? { ...body, customer: { customerId: caller.value.tenantId } } : body;
    if (journal.context !== null && journal.context !== context) return yield* Effect.fail(new UpstreamError({ operation: "createVmContext", status: null }));
    yield* journal.beforeSend(context, {
      provider: yield* providerContext(config),
      environment: config.environment,
      request,
      ...((sourceId ?? imageId) === null ? {} : { source: yield* digest(JSON.stringify(["source", sourceId ?? imageId])) }),
    });
    const checked = (vm: typeof Receipt.Type) => {
      if (!vm.id || vm.slug !== slug || !Object.entries(metadata).every(([k, v]) => vm.metadata[k] === v) ||
        ((sourceId ?? imageId) !== null && vm.snapshotId !== (sourceId ?? imageId)) || vm.idleTimeoutSeconds !== spec.idleTimeoutSeconds) return Effect.fail(new UpstreamError({ operation: "createVmReceipt", status: null }));
      return Effect.succeed(vm);
    };
    const recover = http.json("recoverCreateVm", "GET", `/v5/vms/${encodeURIComponent(slug)}`).pipe(
      Effect.flatMap(decode), Effect.flatMap(checked), Effect.map(Option.some),
      Effect.catchAll((error) => error.status === 404 ? Effect.succeed(Option.none<typeof Receipt.Type>()) : Effect.fail(error)),
    );
    const existing = yield* recover;
    const created = Option.isSome(existing) ? existing.value : yield* Effect.gen(function* () {
      if (imageId !== null) {
        const snapshot = yield* http.json("verifyBootImage", "GET", `/v5/snapshots/${encodeURIComponent(imageId)}`).pipe(
          Effect.flatMap(Schema.decodeUnknown(Schema.Struct({ id: UpstreamId }))),
          Effect.mapError(() => new UpstreamError({ operation: "verifyBootImage", status: null })),
        );
        if (snapshot.id !== imageId) return yield* Effect.fail(new UpstreamError({ operation: "verifyBootImage", status: null }));
      }
      const token = yield* journal.beginSend();
      return yield* http.json("createVm", "POST", "/v5/vms", sent, { timeoutMs: 120_000 }).pipe(
        Effect.flatMap(decode), Effect.flatMap(checked),
        // A rejection counts only once the exact slug also answers 404: a 409 may mean the slug already exists.
        Effect.catchAll((error) => recover.pipe(Effect.flatMap((found) => Option.isSome(found) ? Effect.succeed(found.value)
          : definitelyRejected(error.status) ? journal.rejected(token).pipe(Effect.zipRight(Effect.fail(error))) : Effect.fail(error)))),
      );
    });
    const path = `/v5/vms/${encodeURIComponent(created.id)}`;
    const discard = http.json("discardVm", "DELETE", path).pipe(Effect.ignore);
    const grow = (size: SizeRequest) => {
      const growth: Record<string, number> = {};
      if (size.vcpus !== undefined && size.vcpus > created.resources.cpu) growth["cpu"] = size.vcpus;
      if (size.memoryMib !== undefined && size.memoryMib > created.resources.memory) growth["memory"] = size.memoryMib;
      if (size.diskMib !== undefined && size.diskMib > created.resources.storage) growth["storage"] = size.diskMib;
      return journal.active.pipe(Effect.zipRight(Object.keys(growth).length === 0 ? Effect.succeed(created) : http.json("resizeVm", "POST", `${path}/resize`, growth, { timeoutMs: 120_000 }).pipe(
        Effect.flatMap(Schema.decodeUnknown(UpstreamVm)), Effect.mapError(() => new UpstreamError({ operation: "resizeVm", status: null })),
        Effect.flatMap((vm) => resourceFloorsReached(vm, size) ? Effect.succeed(vm) : Effect.fail(new UpstreamError({ operation: "resizeVm", status: null }))),
        Effect.catchAll((error) => http.json("resizeVm", "GET", path).pipe(
          Effect.flatMap(Schema.decodeUnknown(UpstreamVm)), Effect.mapError(() => error),
          Effect.flatMap((vm) => resourceFloorsReached(vm, size) ? Effect.succeed(vm) : Effect.fail(error)),
        )),
      )));
    };
    return { upstreamId: created.id, vm: created, discard, grow };
  });
};

const providerContext = (config: UpstreamConfig) => digest(JSON.stringify(["provider", config.baseUrl, Redacted.value(config.apiKey), config.environment]));
const checkProvider = (config: UpstreamConfig, retained: VmCreationEvidence) => providerContext(config).pipe(Effect.flatMap((current) =>
  retained.intent.probe.provider === current && retained.intent.probe.environment === config.environment ? Effect.void : Effect.fail(new UpstreamError({ operation: "recoverCreateContext", status: null }))));

/** Shared exact-slug inspection. Cancellation may delete partial resources; recovery must meet all floors. */
const inspectCreation = (config: UpstreamConfig, tenantId: string, vmId: string, retained: VmCreationEvidence, ready: boolean) => Effect.gen(function* () {
  yield* checkProvider(config, retained);
  const { probe, receipt, floors } = retained.intent;
  const slug = `cmux-vm-${config.environment}-${vmId.replace("_", "-")}`;
  const found = yield* makeUpstreamHttp(config).json("recoverCreateVm", "GET", `/v5/vms/${encodeURIComponent(slug)}`).pipe(
    Effect.flatMap(Schema.decodeUnknown(Receipt)), Effect.map(Option.some),
    Effect.catchAll((error) => error instanceof UpstreamError && error.status === 404 ? Effect.succeed(Option.none<typeof Receipt.Type>()) : Effect.fail(new UpstreamError({ operation: "recoverCreateVm", status: null }))),
  );
  if (Option.isNone(found)) return null;
  const machine = found.value;
  if (machine.slug !== slug || machine.metadata["cmux_id"] !== vmId || machine.metadata["cmux_env"] !== probe.environment
    || (tenantId.length <= 63 && machine.metadata["cmux_tenant"] !== tenantId)
    || (retained.createdBy.length <= 63 && machine.metadata["cmux_actor"] !== retained.createdBy)
    || machine.metadata["cmux_create"] !== probe.request
    || (ready && machine.idleTimeoutSeconds !== receipt.idleTimeoutSeconds)
    || (probe.source !== undefined && (machine.snapshotId === undefined || machine.snapshotId === null || (yield* digest(JSON.stringify(["source", machine.snapshotId]))) !== probe.source))) {
    return yield* Effect.fail(new UpstreamError({ operation: "recoverCreateReceipt", status: null }));
  }
  return !ready || resourceFloorsReached(machine, floors) ? { upstreamId: machine.id } : null;
});
export const makeRecoverCreation = (config: UpstreamConfig): UpstreamClientService["recoverCreation"] =>
  (caller, vm, { pending }) => inspectCreation(config, caller.value.tenantId, vm.value, pendingVmCreationEvidenceOf(pending), true);
export const makeInspectCancellation = (config: UpstreamConfig): UpstreamClientService["inspectCancellingCreation"] =>
  (caller, vm, { cancelling }) => inspectCreation(config, caller.value.tenantId, vm.value, cancellingVmCreationEvidenceOf(cancelling), false);
export const makeDeleteCancellation = (config: UpstreamConfig): UpstreamClientService["deleteCancellingCreation"] =>
  (_caller, _vm, { cancelling, owns }) => checkProvider(config, cancellingVmCreationEvidenceOf(cancelling)).pipe(Effect.zipRight(
    makeUpstreamHttp(config).json("cancelCreateVm", "DELETE", `/v5/vms/${encodeURIComponent(upstreamIdOf(owns))}`).pipe(
      Effect.asVoid, Effect.catchAll((error) => error.status === 404 ? Effect.void : Effect.fail(error)),
    ),
  ));
