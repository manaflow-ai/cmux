/** Recovery is confined to an intent's exact unique slug, authorized by its retained create proof. */
import { Effect, Either, Option, Redacted, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { logTimedEvent, timedPhase, type TimedPhases } from "../lib/timing.ts";
import { PROVIDER_CREATE_BUDGET_MS, type CreateAdmissionClient } from "../limits/create-admission.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { vmImageEvidenceOf } from "../proofs/vm-image.ts";
import { initialNetworkBody } from "./initial-network.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import { CREATE_QUEUE_FULL, resourceFloorsReached, UpstreamError, UpstreamVm, type SizeRequest, type UpstreamClientService } from "./client.ts";
import type { UpstreamConfig } from "./live.ts";
import { pendingVmCreationEvidenceOf, cancellingVmCreationEvidenceOf, type VmCreationEvidence } from "../proofs/vm-creation.ts";
import { upstreamName } from "./naming.ts";
import type { Environment } from "../policy.ts";
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

/**
 * A staging or dev VM is a test machine: unless its create asked for its own autoDeleteSeconds, Freestyle deletes it
 * once it has gone this long without running (every start resets the clock; a running VM is never deleted for it).
 * 2026-11-27 00:05Z, GET /v5/vms: 1,021 cmux-vm-staging VMs, 908 of them paused or stopped and none deleted, up from 115
 * on 2026-11-21 (docs fleet/vm-population-delete-paths); each paused 5 min after its last use (idleTimeoutSeconds 300)
 * and then kept its disk forever. Production (and local tests) keep exactly what was asked: a user's machine is never
 * timed out here.
 */
export const NON_PRODUCTION_AUTO_DELETE_SECONDS = 24 * 3600;
const AUTO_DELETED_ENVIRONMENTS: ReadonlySet<Environment> = new Set<Environment>(["staging", "preview"]);

export const autoDeleteFor = (environment: Environment, asked: number | undefined): number | undefined =>
  asked ?? (AUTO_DELETED_ENVIRONMENTS.has(environment) ? NON_PRODUCTION_AUTO_DELETE_SECONDS : undefined);

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

/**
 * Takes a provider create slot for `holder` and answers how to give it back. A refusal (the wait ahead was past the
 * budget, or no slot came within it) fails the create before anything is sent. A queue that cannot be reached does
 * not stop creates: the create is sent as it was before the queue existed, and the line says so.
 */
const admitSend = (admission: CreateAdmissionClient | undefined, holder: string, phases: TimedPhases | undefined, background: boolean): Effect.Effect<Effect.Effect<void>, UpstreamError> => {
  if (admission === undefined) return Effect.succeed(Effect.void);
  if (background && phases !== undefined) phases["admitBackground"] = true;
  return timedPhase(phases, "admitWaitMs", Effect.tryPromise(() => admission.admit(holder, background))).pipe(
    Effect.matchEffect({
      onFailure: () => logTimedEvent("vm_create_admission_unavailable", { vmId: holder }).pipe(Effect.as(Effect.void)),
      onSuccess: (outcome) => {
        if (phases !== undefined) {
          phases["admitInFlight"] = outcome.inFlight;
          phases["admitQueued"] = outcome.queued;
          phases["admitQueueMs"] = outcome.waitedMs;
        }
        if (outcome.admitted) return Effect.succeed(Effect.tryPromise(() => admission.release(holder)).pipe(Effect.ignore));
        if (phases !== undefined) {
          phases["admission"] = outcome.reason;
          phases["admitRetryAfterMs"] = Math.round(outcome.retryAfterMs);
        }
        return Effect.fail(new UpstreamError({ operation: CREATE_QUEUE_FULL, status: null }));
      },
    }),
  );
};

/**
 * How long a provider create may hold its create slot (limits/create-admission.ts), its background polls included:
 * past this, the create is given up as unanswered and its slot goes to the next create. PATCH, not a fix at the
 * cause: the cause is the provider holding some creates before it starts them.
 *
 * Staging 2026-11-27 (ask-6b8661d57a), 3 or fewer in flight:
 * - 14:30-14:45Z, before background requests: 72 creates, createMs p50 1.7 s, p90 82 s, 7 at the 120 s timeout, while
 *   the provider's own providerTotalMs was p50 1.3 s, p90 2.5 s, max 38.6 s; each timed-out create's exact-slug read
 *   answered 404. 364 creates in that window were refused 503 queue_full/wait_expired; the platform's went
 *   create_overdue.
 * - 15:52-16:00Z, with background requests (#61044): 6 of 11 creates failed at 129-152 s with no VM, each holding a
 *   slot the whole time; 42 were refused queue_full/wait_expired and POST /v1/vms answered 503 48 times against 5 201s.
 *
 * 45 s (PROVIDER_CREATE_BUDGET_MS, which the slot's lease also derives from) is above the provider's slowest own
 * time seen (38.6 s). A cut create's exact-slug read below, and the same
 * key's retry (whose first step is that read: "recovered"), find its VM if the provider makes it later; one no create
 * records is deleted by the orphan sweep (upstream/orphan-sweep.ts, cmux_vm_orphan_sweep). "createCut" marks a
 * create given up here, so a later "recovered" under the same key counts a held create the provider did make.
 */
export const CREATE_SEND_TIMEOUT_MS = PROVIDER_CREATE_BUDGET_MS;
/** A create the provider is still working on after this long answers 202 and is polled, within the send timeout. */
export const CREATE_BACKGROUND_AFTER_SECS = 20;

export const makeDurableCreate = (config: UpstreamConfig, baseImageFor: (size: SizeRequest | undefined) => string | null): UpstreamClientService["createVm"] => {
  const http = makeUpstreamHttp(config);
  const decode = (body: unknown) => Schema.decodeUnknown(Receipt)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "createVm", status: null })));
  return (caller, spec, { source, image, network, mesh }) => Effect.gen(function* () {
    const journal = spec.journal;
    if (!journal) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: null }));
    const phases = spec.phases;
    const networkId = mesh === undefined ? null : upstreamIdOf(mesh.owns);
    /** The provider's latest answer describing this creation's VM: the create's own, or an exact-slug read's. */
    let answer: unknown = null;
    const keep = (body: unknown) => Effect.sync(() => { answer = body; });
    const sourceId = source === undefined ? null : upstreamIdOf(source.owns);
    const sourceDigest = (id: string) => digest(JSON.stringify(["source", id]));
    // An approved image revision may have two snapshots of one bake (its own and a large one, proofs/vm-image.ts).
    // A first attempt boots the one the proof chose. A resumed creation keeps the one it was journaled from, named
    // by its retained source digest: the switch may have changed or the entry gained a large snapshot since, and the
    // VM that attempt may have made is found and checked as what it is, never created a second time from the other.
    const approved = image === undefined ? null : vmImageEvidenceOf(image);
    const booted = approved?.other !== undefined && journal.source !== null && (yield* sourceDigest(approved.other.snapshotId)) === journal.source ? approved.other : approved;
    const imageId = booted?.snapshotId ?? null;
    if (phases !== undefined && booted !== null) phases["imageVariant"] = booted.variant;
    if (sourceId !== null && imageId !== null) return yield* Effect.fail(new UpstreamError({ operation: "createVm", status: 400 }));
    const slug = `cmux-vm-${config.environment}-${spec.cmuxId.replace("_", "-")}`;
    const metadata: Record<string, string> = { cmux_id: spec.cmuxId, cmux_env: spec.environment };
    if (spec.createdBy !== undefined && spec.createdBy.length <= 63) metadata["cmux_actor"] = spec.createdBy;
    if (caller.value.tenantId.length <= 63) metadata["cmux_tenant"] = caller.value.tenantId;
    const autoDeleteSeconds = autoDeleteFor(config.environment, spec.autoDeleteSeconds);
    const body = {
      slug, displayName: upstreamName(config.environment, caller.value.tenantId, spec.cmuxId), metadata,
      idleTimeoutSeconds: spec.idleTimeoutSeconds,
      ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
      ...(autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds }),
      ...initialNetworkBody(network),
      ...((sourceId ?? imageId ?? baseImageFor(spec.size)) === null ? {} : { snapshotId: sourceId ?? imageId ?? baseImageFor(spec.size) }),
    };
    const request = yield* digest(JSON.stringify(body));
    metadata["cmux_create"] = request;
    const context = yield* digest(JSON.stringify([config.baseUrl, Redacted.value(config.apiKey), body]));
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
    // A resumed image creation whose journaled source is neither snapshot the entry lists now: the entry lost or
    // replaced its large snapshot after the first attempt booted it (an operator must not, README; this is the net
    // under that rule). The journal holds only that snapshot's digest, so what is sent today can never match the
    // retained context. The VM the first attempt may have made is still this creation's, so the exact slug is read
    // before anything fails, and a VM found there is held to the journal (its request digest and its source digest)
    // instead of to today's entry: same image id and revision, the snapshot that revision had when it booted.
    // Nothing found fails as it did before (createVmContext), and nothing is sent: the retained intent binds this key's
    // VM id to the journaled request, so a create from today's entry would carry another request digest under the
    // same slug, which neither this path nor creation recovery (inspectCreation) would ever accept as this creation's.
    // A new Idempotency-Key creates from the entry as it is now.
    const unlisted = approved !== null && imageId !== null && journal.source !== null && journal.request !== null
      && journal.context !== null && journal.context !== context && (yield* sourceDigest(imageId)) !== journal.source;
    if (unlisted && phases !== undefined) phases["imageVariant"] = "unlisted";
    if (!unlisted) {
      if (journal.context !== null && journal.context !== context) return yield* Effect.fail(new UpstreamError({ operation: "createVmContext", status: null }));
      yield* journal.beforeSend(context, {
        provider: yield* providerContext(config),
        environment: config.environment,
        request,
        ...((sourceId ?? imageId) === null ? {} : { source: yield* sourceDigest(String(sourceId ?? imageId)) }),
      });
    }
    // A receipt that differs from the request can never be committed: recovery checks the same fields. When the answer
    // to this request's own POST describes a VM that is provably this creation's (exact slug and every metadata value
    // this request sent, so only its source image or idle timeout differs), the VM is deleted before the create fails:
    // a failed create never leaves a VM running with no ownership row (cmux#35013). Only the POST's answer does this,
    // never an exact-slug lookup, which may find a VM an earlier attempt already recorded (an uncommitted row whose
    // owner can see it); a VM at the slug with anyone else's metadata is never touched. A failed delete, and a VM an
    // earlier attempt left unrecorded, is left to the Worker's orphan sweep (src/upstream/orphan-sweep.ts).
    //
    // A VM booted from an image's large snapshot is also held to the size asked: the pick trusted the size the entry
    // declares, sizes only grow, and people are billed by size. One that answers larger than asked on any axis (a wrong
    // entry, a provider that rounds up) is a mismatch like another snapshot: the POST's answer is deleted and the create
    // fails, and a later exact-slug read never adopts it. The line says `oversized`. A failed delete is logged
    // (vm_create_discard_failed, the public VM id only), since the VM then runs unrecorded until the orphan sweep.
    const asked = spec.size;
    const oversized = (vm: typeof Receipt.Type) => booted?.variant === "large" && asked !== undefined && (
      (asked.vcpus !== undefined && vm.resources.cpu > asked.vcpus) || (asked.memoryMib !== undefined && vm.resources.memory > asked.memoryMib)
      || (asked.diskMib !== undefined && vm.resources.storage > asked.diskMib));
    const discardMismatched = (vm: typeof Receipt.Type) => vm.id && vm.slug === slug && Object.entries(metadata).every(([k, v]) => vm.metadata[k] === v)
      ? http.json("discardMismatchedVm", "DELETE", `/v5/vms/${encodeURIComponent(vm.id)}`).pipe(
          Effect.asVoid,
          Effect.catchAll((error) => logTimedEvent("vm_create_discard_failed", { vmId: spec.cmuxId, reason: oversized(vm) ? "oversized" : "receipt", status: error.status })),
        )
      : Effect.void;
    const matches = (vm: typeof Receipt.Type) => !(!vm.id || vm.slug !== slug || !Object.entries(metadata).every(([k, v]) => vm.metadata[k] === v) ||
      ((sourceId ?? imageId) !== null && vm.snapshotId !== (sourceId ?? imageId)) || !sameIdleTimeout(vm.idleTimeoutSeconds, spec.idleTimeoutSeconds));
    const receiptError = () => new UpstreamError({ operation: "createVmReceipt", status: null });
    /** The VM is this creation's and no larger than asked; otherwise why not, noted on the line. */
    const accepted = (vm: typeof Receipt.Type) => {
      if (!matches(vm)) return false;
      if (!oversized(vm)) return true;
      if (phases !== undefined) phases["oversized"] = true;
      return false;
    };
    const checked = (vm: typeof Receipt.Type) => accepted(vm) ? Effect.succeed(vm) : Effect.fail(receiptError());
    const checkedSent = (vm: typeof Receipt.Type) => accepted(vm) ? Effect.succeed(vm) : discardMismatched(vm).pipe(Effect.zipRight(Effect.fail(receiptError())));
    const journaled = http.json("recoverCreateVm", "GET", `/v5/vms/${encodeURIComponent(slug)}`).pipe(
      Effect.tap(keep), Effect.flatMap(decode),
      Effect.catchAll((error) => Effect.fail(error.status === 404 ? new UpstreamError({ operation: "createVmContext", status: null }) : error)),
      Effect.flatMap((vm) => sourceDigest(vm.snapshotId ?? "").pipe(Effect.flatMap((from) =>
        vm.id && vm.slug === slug && Object.entries({ ...metadata, cmux_create: journal.request }).every(([k, v]) => vm.metadata[k] === v)
          && typeof vm.snapshotId === "string" && from === journal.source && sameIdleTimeout(vm.idleTimeoutSeconds, spec.idleTimeoutSeconds)
          ? Effect.succeed(vm) : Effect.fail(receiptError())))),
    );
    const recover = http.json("recoverCreateVm", "GET", `/v5/vms/${encodeURIComponent(slug)}`).pipe(
      Effect.tap(keep), Effect.flatMap(decode), Effect.flatMap(checked), Effect.map(Option.some),
      Effect.catchAll((error) => error.status === 404 ? Effect.succeed(Option.none<typeof Receipt.Type>()) : Effect.fail(error)),
    );
    const verifyImage = (id: string) => http.json("verifyBootImage", "GET", `/v5/snapshots/${encodeURIComponent(id)}`).pipe(
      Effect.flatMap(Schema.decodeUnknown(Schema.Struct({ id: UpstreamId }))),
      Effect.mapError(() => new UpstreamError({ operation: "verifyBootImage", status: null })),
      Effect.flatMap((snapshot) => snapshot.id === id ? Effect.void : Effect.fail(new UpstreamError({ operation: "verifyBootImage", status: null }))),
    );
    // The exact-slug recovery read and the boot image read do not depend on each other, so they are in flight together
    // (each is a provider round trip of 0.45 to 1.9 s). The outcome is the one the serial order gave: a failed recovery
    // read fails the create with its own error, a recovered VM is the answer whatever the image read said, and only
    // when nothing was recovered does a failed image read fail the create, before anything is sent. The image read's
    // verdict is held as a value so that it cannot fail the pair.
    //
    // With `withoutReads` (the caller's switch) neither read is made on a first attempt:
    // - The exact-slug read finds a VM an earlier attempt under this key made and lost the answer of. The slug carries
    //   the VM id, and an id minted in this request has been sent to the provider by no one, so there is nothing to
    //   find. A resumed creation (journal.minted false) reads first as before, and the read after a failed create
    //   below is kept for every attempt.
    // - The boot image read finds a listed snapshot the provider no longer has before anything is sent. The create's
    //   answer is already held to the approved snapshot (`matches`: any other snapshot id deletes the VM and fails the
    //   create, cmux#35013), which is what covered a snapshot deleted between the read and the create. So without the
    //   read a missing snapshot is the provider's refusal of the create (marked rejected once the exact slug answers
    //   404), or a VM booted from anything else, deleted: nothing is recorded either way, and the caller sees the
    //   same 503.
    const readFirst = spec.withoutReads !== true;
    const [existing, imageVerdict] = unlisted ? [Option.some(yield* timedPhase(phases, "recoverMs", journaled)), Either.void] as const : yield* Effect.all([
      readFirst || !journal.minted ? timedPhase(phases, "recoverMs", recover) : Effect.succeed(Option.none<typeof Receipt.Type>()),
      imageId === null || !readFirst ? Effect.succeed(Either.void) : timedPhase(phases, "verifyImageMs", Effect.either(verifyImage(imageId))),
    ], { concurrency: "unbounded" });
    if (phases !== undefined) phases["recovered"] = Option.isSome(existing);
    const created = Option.isSome(existing) ? existing.value : yield* Effect.gen(function* () {
      if (Either.isLeft(imageVerdict)) return yield* Effect.fail(imageVerdict.left);
      // A provider create slot (limits/create-admission.ts) is taken before the send begins, so a refusal sent
      // nothing and the same key's retry starts clean, like a failed image read above.
      const release = yield* admitSend(config.createAdmission, spec.cmuxId, phases, spec.background === true);
      const token = yield* journal.beginSend().pipe(Effect.onError(() => release));
      // Staging, 2026-11-27 05:51-06:01Z: in a burst of creates the provider held POST /v5/vms past the 120 s cut, 13
      // creates failed at createMs 120000 with no VM yet under the slug to recover, and the caller's retries ran a
      // journey's create past its 300 s bound. As a background request it answers 202 after 60 s and the stored
      // answer (the VM) is polled, so a slow create is still one create with its answer. A create with no answer at all
      // in CREATE_SEND_TIMEOUT_MS, polls included, gives its slot back (see that constant).
      return yield* timedPhase(phases, "createMs", http.json("createVm", "POST", "/v5/vms", sent, { timeoutMs: CREATE_SEND_TIMEOUT_MS, backgroundUntil: Date.now() + CREATE_SEND_TIMEOUT_MS, backgroundAfterSecs: CREATE_BACKGROUND_AFTER_SECS }).pipe(
        Effect.tap(keep),
        Effect.tap((body) => Effect.sync(() => { if (phases !== undefined) Object.assign(phases, providerTimings(body)); })),
        Effect.flatMap(decode), Effect.flatMap(checkedSent),
      )).pipe(
        Effect.ensuring(release),
        // A rejection counts only once the exact slug also answers 404: a 409 may mean the slug already exists.
        Effect.tapError((error) => Effect.sync(() => { if (phases !== undefined && error.status === null) phases["createCut"] = true; })),
        Effect.catchAll((error) => timedPhase(phases, "recoverAfterMs", recover).pipe(Effect.flatMap((found) => Option.isSome(found)
          ? Effect.sync(() => { if (phases !== undefined) phases["recovered"] = true; return found.value; })
          : definitelyRejected(error.status) ? journal.rejected(token).pipe(Effect.zipRight(Effect.fail(error))) : Effect.fail(error)))),
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
