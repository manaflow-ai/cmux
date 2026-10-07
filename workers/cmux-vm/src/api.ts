/**
 * The public cmux VM HTTP API. Every request and response has a Schema. The
 * checked-in openapi.json is generated from this definition
 * (scripts/generate-openapi.ts) and the Rust and TypeScript clients are
 * generated from that document, so this file is the contract.
 */
import { HttpApi, HttpApiEndpoint, HttpApiGroup, HttpApiMiddleware, HttpApiSchema, HttpApiSecurity, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { CurrentPrincipal } from "./domain/principal.ts";
import {
  Conflict,
  Forbidden,
  NotFound,
  NotImplemented,
  PaymentRequired,
  QuotaExceeded,
  ServiceUnavailable,
  Unauthorized,
} from "./errors.ts";
import { SnapshotId, VmId } from "./lib/ids.ts";

/**
 * Bearer authentication: a Stack Auth session token (with `X-Cmux-Team-Id`
 * naming the team) or a cmux VM API key (`cmuxvm_sk_...`).
 */
export class Authentication extends HttpApiMiddleware.Tag<Authentication>()("cmux-vm/Authentication", {
  failure: Schema.Union(Unauthorized, Forbidden, ServiceUnavailable),
  provides: CurrentPrincipal,
  security: {
    bearer: HttpApiSecurity.bearer.pipe(
      HttpApiSecurity.annotate(
        OpenApi.Description,
        "A cmux VM API key (cmuxvm_sk_...), or a cmux session token together with the X-Cmux-Team-Id header.",
      ),
    ),
  },
}) {}

export const VmState = Schema.Literal("starting", "running", "pausing", "paused", "stopped", "unknown");
export type VmState = typeof VmState.Type;

export class Vm extends Schema.Class<Vm>("Vm")({
  id: VmId,
  state: VmState,
  resources: Schema.Struct({
    vcpus: Schema.Number,
    memoryMib: Schema.Number,
    diskMib: Schema.Number,
  }),
  idleTimeoutSeconds: Schema.NullOr(Schema.Number),
  createdAt: Schema.String,
  updatedAt: Schema.String,
}) {}

export class VmList extends Schema.Class<VmList>("VmList")({
  items: Schema.Array(Vm),
  /** Pass as `cursor` to read the next page; null on the last page. */
  nextCursor: Schema.NullOr(Schema.String),
}) {}

/** Seconds without network activity before the VM pauses; -1 never pauses. */
const IdleTimeoutSeconds = Schema.Int.pipe(Schema.between(-1, 7 * 24 * 60 * 60));
const DisplayName = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100));

export class CreateVmRequest extends Schema.Class<CreateVmRequest>("CreateVmRequest")({
  displayName: Schema.optional(DisplayName),
  /** Boot from one of the tenant's snapshots; omit for the default image. */
  snapshotId: Schema.optional(SnapshotId),
  idleTimeoutSeconds: Schema.optional(IdleTimeoutSeconds),
}) {}

export class ForkVmRequest extends Schema.Class<ForkVmRequest>("ForkVmRequest")({
  displayName: Schema.optional(DisplayName),
  idleTimeoutSeconds: Schema.optional(IdleTimeoutSeconds),
}) {}

export const ListVmsParams = Schema.Struct({
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 100))),
  cursor: Schema.optional(Schema.String.pipe(Schema.maxLength(512))),
  state: Schema.optional(VmState),
});

/** With a session token, names the team (tenant) the request acts for. Ignored for API keys. */
const teamHeader = { "x-cmux-team-id": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128))) };

export const TeamHeaders = Schema.Struct(teamHeader);

/** Retrying a create with the same idempotency key returns the first result instead of creating twice. */
export const CreateHeaders = Schema.Struct({
  ...teamHeader,
  "idempotency-key": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(255))),
});

const VmPath = Schema.Struct({ vmId: Schema.String });

const describe = (summary: string, scope: string) =>
  OpenApi.annotations({ summary, description: `${summary}. Requires the ${scope} scope.` });

export class Health extends Schema.Class<Health>("Health")({ ok: Schema.Literal(true) }) {}

export class HealthGroup extends HttpApiGroup.make("health").add(
  HttpApiEndpoint.get("health", "/healthz")
    .addSuccess(Health)
    .annotateContext(OpenApi.annotations({ summary: "Liveness check; no credentials needed" })),
) {}

/** A VM action that answers with the VM's new state. */
const vmAction = <const Name extends string>(endpointName: Name, path: `/v1/vms/:vmId/${string}`, summary: string) =>
  HttpApiEndpoint.post(endpointName, path)
    .setPath(VmPath)
    .setHeaders(TeamHeaders)
    .addSuccess(Vm)
    .addError(NotFound)
    .addError(Conflict)
    .addError(NotImplemented)
    .annotateContext(describe(summary, "vm:write"));

export class VmsGroup extends HttpApiGroup.make("vms")
  .add(
    HttpApiEndpoint.post("createVm", "/v1/vms")
      .setPayload(CreateVmRequest)
      .setHeaders(CreateHeaders)
      .addSuccess(Vm, { status: 201 })
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .addError(NotImplemented)
      .annotateContext(describe("Create a VM", "vm:write")),
  )
  .add(
    HttpApiEndpoint.get("listVms", "/v1/vms")
      .setUrlParams(ListVmsParams)
      .setHeaders(TeamHeaders)
      .addSuccess(VmList)
      .addError(NotImplemented)
      .annotateContext(describe("List the tenant's VMs", "vm:read")),
  )
  .add(
    HttpApiEndpoint.get("getVm", "/v1/vms/:vmId")
      .setPath(VmPath)
      .setHeaders(TeamHeaders)
      .addSuccess(Vm)
      .addError(NotFound)
      .annotateContext(describe("Get a VM", "vm:read")),
  )
  .add(vmAction("startVm", "/v1/vms/:vmId/start", "Start a stopped VM"))
  .add(vmAction("stopVm", "/v1/vms/:vmId/stop", "Stop a running VM"))
  .add(vmAction("pauseVm", "/v1/vms/:vmId/pause", "Pause a running VM, keeping its memory"))
  .add(vmAction("resumeVm", "/v1/vms/:vmId/resume", "Resume a paused VM"))
  .add(
    HttpApiEndpoint.post("forkVm", "/v1/vms/:vmId/fork")
      .setPath(VmPath)
      .setPayload(ForkVmRequest)
      .setHeaders(CreateHeaders)
      .addSuccess(Vm, { status: 201 })
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .addError(NotImplemented)
      .annotateContext(describe("Fork a VM into a new VM with the same memory and disk", "vm:write")),
  )
  .add(
    HttpApiEndpoint.del("deleteVm", "/v1/vms/:vmId")
      .setPath(VmPath)
      .setHeaders(TeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(Conflict)
      .addError(NotImplemented)
      .annotateContext(describe("Delete a VM permanently", "vm:write")),
  )
  .middleware(Authentication) {}

export class CmuxVmApi extends HttpApi.make("cmux-vm")
  .add(HealthGroup)
  .add(VmsGroup)
  .annotateContext(
    OpenApi.annotations({
      title: "cmux VM API",
      version: "0.1.0",
      description: "Tenant-scoped virtual machines for cmux.",
      servers: [{ url: "https://vm.cmux.com", description: "Production" }, { url: "https://vm-staging.cmux.com", description: "Staging" }],
    }),
  ) {}
