/** Recovery is confined to an intent's exact unique slug, authorized by its retained create proof. */
import { Effect, Either, Option, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { timedPhase } from "../lib/timing.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { vmImageEvidenceOf } from "../proofs/vm-image.ts";
import { initialNetworkBody } from "./initial-network.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import { resourceFloorsReached, UpstreamError, UpstreamVm, type SizeRequest, type UpstreamClientService } from "./client.ts";
import type { UpstreamConfig } from "./live.ts";
import { pendingVmCreationEvidenceOf, cancellingVmCreationEvidenceOf, type VmCreationEvidence } from "../proofs/vm-creation.ts";
import { upstreamName } from "./naming.ts";
import { vaultTenantMetadata } from "./vault-tenant.ts";

const Receipt = Schema.Struct({ id: UpstreamId, ...UpstreamVm.fields, slug: Schema.String, metadata: Schema.Record({ key: Schema.String, value: Schema.String }), snapshotId: Schema.optional(Schema.NullOr(Schema.String)) });
const digest = (text: string) => Effect.promise(async () => {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
});

/** The provider's own customer id rule (freestyle@0.2.21 `Customer.customerId`). */
const CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/u;

/** 4xx answers that prove the provider made nothing; 408 (timeout), 409 (slug may exist), 5xx and transport errors do not. */
/**
 * The provider takes -1 (or no value) as "never pause" on a create but reports such a VM's timeout as null: its Vm
 * schema has a minimum of 0. Comparing the raw values failed every production create with the product default of
 * -1 (2026-11-04: 503 on each create, the VM made upstream and left unrecorded).
 */
const sameIdleTimeout = (reported: number | null | undefined, requested: number) =>
  reported === requested || (requested < 0 && (reported === null || reported === undefined || reported < 0));

const definitelyRejected = (status: number | null) => status !== null && status >= 400 && status < 500 && status !== 408 && status !== 409;

const field = (value: unknown, key: string): unknown => (typeof value === "object" && value !== null ? Reflect.get(value, key) : undefined);
const IPV4 = /^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$/u;

/**
 * The VM's address on `networkId`, read leniently from a provider VM answer (`vpcs`, or `networks` for old readers):
 * only when the answer lists exactly that one network, under one consistent id, with an IPv4 address. Anything else
 * is null, which claims nothing: a later attach sets the network declaratively.
 */
const joinedOn = (answer: unknown, networkId: string): { readonly ipv4: string } | null => {
  const vpcs = field(answer, "vpcs"), networks = field(answer, "networks");
  // Both names present must say the same thing, as readVmAddress requires (live-mesh.ts): an answer whose two lists
  // disagree is not "on exactly that network".
  if (vpcs != null && networks != null && JSON.stringify(vpcs) !== JSON.stringify(networks)) return null;
  const listed = vpcs ?? networks;
  if (!Array.isArray(listed) || listed.length !== 1) return null;
  const vpc = field(listed[0], "vpc"), vpcId = field(listed[0], "vpcId"), ipv4 = field(listed[0], "ipv4");
  if (vpc !== networkId || (vpcId !== undefined && vpcId !== null && vpcId !== networkId)) return null;
  return typeof ipv4 === "string" && IPV4.test(ipv4) ? { ipv4 } : null;
};

/** The provider's own phase timings on a create answer (`debug.totalMs`, `debug.timingsMs`): numbers only, bounded. */
const providerTimings = (answer: unknown): { readonly providerTotalMs?: number; readonly providerTimingsMs?: Record<string, number> } => {
  const debug = field(answer, "debug"), total = field(debug, "totalMs"), timings = field(debug, "timingsMs");
  const phases = typeof timings !== "object" || timings === null ? [] : Object.entries(timings)
    .filter((entry): entry is [string, number] => /^[A-Za-z0-9_.-]{1,64}$/u.test(entry[0]) && typeof entry[1] === "number" && Number.isFinite(entry[1]))
    .slice(0, 40);
  return {
    ...(typeof total === "number" && Number.isFinite(total) ? { providerTotalMs: total } : {}),
    ...(phases.length === 0 ? {} : { providerTimingsMs: Object.fromEntries(phases) }),
  };
};

export const makeDurableCreate = (config: UpstreamConfig, baseImageFor: (size: SizeRequest | undefined) => string | null): UpstreamClientService["createVm"] => {
  const http = makeUpstreamHttp(config);
  const decode = (body: unknown) => Schema.decodeUnknown(Receipt)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "createVm", status: null })));
  /**
   * Boot image snapshots the provider has answered for under their own id, for as long as this client lives (one per
   * isolate). Bounded by the image list: 32 entries and their variants.
   */
  const verifiedImages = new Set<string>();
  return (caller, spec, { source, image, network, mesh }) => Effect.gen(function* () {
    const journal = spec.journal;
    if (!journal) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: null }));
    const phases = spec.phases;
    const networkId = mesh === undefined ? null : upstreamIdOf(mesh.owns);
    /** The provider's latest answer describing this creation's VM: the create's own, or an exact-slug read's. */
    let answer: unknown = null;
    const keep = (body: unknown) => Effect.sync(() => { answer = body; });
    const sourceId = source === undefined ? null : upstreamIdOf(source.owns);
    const approved = image === undefined ? null : vmImageEvidenceOf(image);
    if (sourceId !== null && approved !== null) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
    const slug = `cmux-vm-${config.environment}-${spec.cmuxId.replace("_", "-")}`;
    const identity: Record<string, string> = { cmux_id: spec.cmuxId, cmux_env: spec.environment };
    if (spec.createdBy !== undefined && spec.createdBy.length <= 63) identity["cmux_actor"] = spec.createdBy;
    if (caller.value.tenantId.length <= 63) identity["cmux_tenant"] = caller.value.tenantId;
    /**
     * The request that boots `snapshot`, with its digests. The body's fields, their order and both digests are the
     * ones every create journaled so far has, so a retry of an older create still matches its retained context.
     */
    const planFor = (snapshot: string | null, variant: string | null) => Effect.gen(function* () {
      const metadata = { ...identity };
      const body = {
        slug, displayName: upstreamName(config.environment, caller.value.tenantId, spec.cmuxId), metadata,
        idleTimeoutSeconds: spec.idleTimeoutSeconds,
        ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
        ...(spec.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: spec.autoDeleteSeconds }),
        ...initialNetworkBody(network),
        ...(snapshot === null ? {} : { snapshotId: snapshot }),
      };
      const request = yield* digest(JSON.stringify(body));
      metadata["cmux_create"] = request;
      const context = yield* digest(JSON.stringify([config.baseUrl, Redacted.value(config.apiKey), body]));
      return { snapshot, variant, body, metadata, request, context };
    });
    // An approved image boots the variant baked at exactly the asked size, when it lists one: the VM is then made at
    // its final size and `grow` below finds nothing to grow, so no resize call follows the create. Any other ask
    // boots the image's own snapshot and grows, as before. `boots` is every snapshot this create may boot, the one a
    // first attempt takes first.
    const size = spec.size;
    const fitted = approved === null || size === undefined ? undefined
      : approved.variants.find((variant) => variant.vcpus === size.vcpus && variant.memoryMib === size.memoryMib && variant.diskMib === size.diskMib);
    const boots: ReadonlyArray<{ readonly snapshot: string | null; readonly variant: string | null }> = approved === null
      ? [{ snapshot: sourceId ?? baseImageFor(size), variant: null }]
      : [
          ...(fitted === undefined ? [] : [{ snapshot: fitted.snapshotId, variant: fitted.name }]),
          { snapshot: approved.snapshotId, variant: "base" },
          ...approved.variants.filter((variant) => variant !== fitted).map((variant) => ({ snapshot: variant.snapshotId, variant: variant.name })),
        ];
    // No earlier attempt under this idempotency key journaled a create: nothing was sent, so no VM is at the slug.
    const firstAttempt = journal.context === null;
    // A retry boots what its first attempt journaled, whatever the image lists now: the snapshot whose context is the
    // retained one. That is the image's own snapshot for a create journaled before the image listed a variant, and
    // the variant after it; when the list no longer has that snapshot, the retry fails here and sends nothing.
    let plan = yield* planFor(boots[0]?.snapshot ?? null, boots[0]?.variant ?? null);
    for (const other of boots.slice(1)) {
      if (firstAttempt || plan.context === journal.context) break;
      plan = yield* planFor(other.snapshot, other.variant);
    }
    if (!firstAttempt && plan.context !== journal.context) return yield* Effect.fail(new UpstreamError({ operation: "createVmContext", status: null }));
    const { body, metadata, request, context } = plan;
    const imageId = approved === null ? null : plan.snapshot;
    // The tenant is the provider's customer (abuse protection tells tenants apart by it). It is sent outside the
    // digests above: it follows from the tenant id the name and metadata already carry, and a create journaled
    // before this field existed must still match its retained request and context.
    const customer = CUSTOMER_ID.test(caller.value.tenantId) ? { ...body, customer: { customerId: caller.value.tenantId } } : body;
    // The vault's VM tenant key (vault-tenant.ts) is outside the digests and the receipt check for the same reason: a
    // create journaled before it existed still matches, and a recovered VM without it is still this creation's.
    const vault = vaultTenantMetadata(spec.environment, caller.value);
    const tagged = vault === null ? customer : { ...customer, metadata: { ...metadata, [vault[0]]: vault[1] } };
    // The mesh network to join at create is outside the digests and the receipt check too: a create journaled before
    // the field existed still matches, and a recovered VM is this creation's whatever network it is on. The handler's
    // idempotency fingerprint carries the mesh (a key cannot be replayed with another), and whether the VM is on the
    // network is read from the provider's answer (`joined` below), never assumed from what was sent.
    const sent = networkId === null ? tagged : { ...tagged, networks: [{ vpc: networkId }] };
    yield* journal.beforeSend(context, {
      provider: yield* providerContext(config),
      environment: config.environment,
      request,
      ...((sourceId ?? imageId) === null ? {} : { source: yield* digest(JSON.stringify(["source", sourceId ?? imageId])) }),
    });
    // From here the create reaches the provider, which is what the handler's vm_create line reports.
    if (phases !== undefined) phases["bootVariant"] = plan.variant;
    // A receipt that differs from the request can never be committed: recovery checks the same fields. When the answer
    // to this request's own POST describes a VM that is provably this creation's (exact slug and every metadata value
    // this request sent, so only its source image or idle timeout differs), the VM is deleted before the create fails:
    // a failed create never leaves a VM running with no ownership row (cmux#35013). Only the POST's answer does this,
    // never an exact-slug lookup, which may find a VM an earlier attempt already recorded (an uncommitted row whose
    // owner can see it); a VM at the slug with anyone else's metadata is never touched. A failed delete, and a VM an
    // earlier attempt left unrecorded, is left to the Worker's orphan sweep (src/upstream/orphan-sweep.ts).
    const discardMismatched = (vm: typeof Receipt.Type) => vm.id && vm.slug === slug && Object.entries(metadata).every(([k, v]) => vm.metadata[k] === v)
      ? http.json("discardMismatchedVm", "DELETE", `/v5/vms/${encodeURIComponent(vm.id)}`).pipe(Effect.ignore)
      : Effect.void;
    const matches = (vm: typeof Receipt.Type) => !(!vm.id || vm.slug !== slug || !Object.entries(metadata).every(([k, v]) => vm.metadata[k] === v) ||
      ((sourceId ?? imageId) !== null && vm.snapshotId !== (sourceId ?? imageId)) || !sameIdleTimeout(vm.idleTimeoutSeconds, spec.idleTimeoutSeconds));
    const receiptError = () => new UpstreamError({ operation: "createVmReceipt", status: null });
    const checked = (vm: typeof Receipt.Type) => matches(vm) ? Effect.succeed(vm) : Effect.fail(receiptError());
    const checkedSent = (vm: typeof Receipt.Type) => matches(vm) ? Effect.succeed(vm) : discardMismatched(vm).pipe(Effect.zipRight(Effect.fail(receiptError())));
    const recover = http.json("recoverCreateVm", "GET", `/v5/vms/${encodeURIComponent(slug)}`).pipe(
      Effect.tap(keep), Effect.flatMap(decode), Effect.flatMap(checked), Effect.map(Option.some),
      Effect.catchAll((error) => error.status === 404 ? Effect.succeed(Option.none<typeof Receipt.Type>()) : Effect.fail(error)),
    );
    const verifyImage = (id: string) => http.json("verifyBootImage", "GET", `/v5/snapshots/${encodeURIComponent(id)}`).pipe(
      Effect.flatMap(Schema.decodeUnknown(Schema.Struct({ id: UpstreamId }))),
      Effect.mapError(() => new UpstreamError({ operation: "verifyBootImage", status: null })),
      Effect.flatMap((snapshot) => snapshot.id === id ? Effect.void : Effect.fail(new UpstreamError({ operation: "verifyBootImage", status: null }))),
    );
    // Neither read is on a normal create's path. The exact-slug recovery read is made only by a retry: a first attempt
    // has sent nothing, its slug carries an id minted for this request, and a slug that does exist answers the create
    // with an error, which is followed by this same read (recoverAfterMs below). The boot image read is made only for
    // a snapshot this isolate has not yet seen the provider answer for under its own id; a snapshot id is immutable,
    // so one answer holds until a create with it fails, which forgets it. A provider that no longer has the snapshot
    // refuses the create itself, and a VM made from any other snapshot fails the receipt check and is deleted.
    // When both reads are due they are in flight together (each is a provider round trip of 0.45 to 1.9 s), with the
    // outcome the serial order gave: a failed recovery read fails the create with its own error, a recovered VM is
    // the answer whatever the image read said, and only when nothing was recovered does a failed image read fail the
    // create, before anything is sent. The image read's verdict is held as a value so that it cannot fail the pair.
    const unverified = imageId !== null && !verifiedImages.has(imageId) ? imageId : null;
    const [existing, imageVerdict] = yield* Effect.all([
      firstAttempt ? Effect.succeed(Option.none<typeof Receipt.Type>()) : timedPhase(phases, "recoverMs", recover),
      unverified === null ? Effect.succeed(Either.void) : timedPhase(phases, "verifyImageMs", Effect.either(verifyImage(unverified))),
    ], { concurrency: "unbounded" });
    if (unverified !== null && Either.isRight(imageVerdict)) verifiedImages.add(unverified);
    if (phases !== undefined) phases["recovered"] = Option.isSome(existing);
    const created = Option.isSome(existing) ? existing.value : yield* Effect.gen(function* () {
      if (Either.isLeft(imageVerdict)) return yield* Effect.fail(imageVerdict.left);
      const token = yield* journal.beginSend();
      return yield* timedPhase(phases, "createMs", http.json("createVm", "POST", "/v5/vms", sent, { timeoutMs: 120_000 }).pipe(
        Effect.tap(keep),
        Effect.tap((body) => Effect.sync(() => { if (phases !== undefined) Object.assign(phases, providerTimings(body)); })),
        Effect.flatMap(decode), Effect.flatMap(checkedSent),
      )).pipe(
        // A rejection counts only once the exact slug also answers 404: a 409 may mean the slug already exists.
        Effect.catchAll((error) => timedPhase(phases, "recoverAfterMs", recover).pipe(Effect.flatMap((found) => {
          if (Option.isSome(found)) return Effect.sync(() => { if (phases !== undefined) phases["recovered"] = true; return found.value; });
          // The create failed and made nothing: the next create with this image asks the provider for it again first.
          if (imageId !== null) verifiedImages.delete(imageId);
          return definitelyRejected(error.status) ? journal.rejected(token).pipe(Effect.zipRight(Effect.fail(error))) : Effect.fail(error);
        }))),
      );
    });
    const joined = networkId === null ? null : joinedOn(answer, networkId);
    const path = `/v5/vms/${encodeURIComponent(created.id)}`;
    const discard = http.json("discardVm", "DELETE", path).pipe(Effect.ignore);
    const grow = (size: SizeRequest) => {
      const growth: Record<string, number> = {};
      if (size.vcpus !== undefined && size.vcpus > created.resources.cpu) growth["cpu"] = size.vcpus;
      if (size.memoryMib !== undefined && size.memoryMib > created.resources.memory) growth["memory"] = size.memoryMib;
      if (size.diskMib !== undefined && size.diskMib > created.resources.storage) growth["storage"] = size.diskMib;
      return journal.active.pipe(Effect.zipRight(Object.keys(growth).length === 0 ? Effect.succeed(created) : timedPhase(phases, "resizeMs", http.json("resizeVm", "POST", `${path}/resize`, growth, { timeoutMs: 120_000 }).pipe(
        Effect.flatMap(Schema.decodeUnknown(UpstreamVm)), Effect.mapError(() => new UpstreamError({ operation: "resizeVm", status: null })),
        Effect.flatMap((vm) => resourceFloorsReached(vm, size) ? Effect.succeed(vm) : Effect.fail(new UpstreamError({ operation: "resizeVm", status: null }))),
        Effect.catchAll((error) => http.json("resizeVm", "GET", path).pipe(
          Effect.flatMap(Schema.decodeUnknown(UpstreamVm)), Effect.mapError(() => error),
          Effect.flatMap((vm) => resourceFloorsReached(vm, size) ? Effect.succeed(vm) : Effect.fail(error)),
        )),
      ))));
    };
    return { upstreamId: created.id, vm: created, discard, grow, joined };
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
    || (ready && !sameIdleTimeout(machine.idleTimeoutSeconds, receipt.idleTimeoutSeconds))
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
