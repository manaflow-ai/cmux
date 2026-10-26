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
  BadRequest,
  Conflict,
  ForkIncomplete,
  Forbidden,
  NotFound,
  PaymentRequired,
  PayloadTooLarge,
  QuotaExceeded,
  ServiceUnavailable,
  Unauthorized,
} from "./errors.ts";
import { SnapshotId, VmId } from "./lib/ids.ts";
import { VmCreationsGroupDefinition } from "./api/creations.ts";
import { SnapshotsGroupDefinition } from "./api/snapshots.ts";
import { TerminalsGroupDefinition } from "./api/terminals.ts";
import { ApiKeysGroupDefinition } from "./api/api-keys.ts";
import { AgentsGroupDefinition } from "./api/agents.ts";
import { ClientSessionsGroupDefinition } from "./api/client-sessions.ts";
import { MeshDeviceGroupDefinition, MeshEnrollGroupDefinition, MeshGroupDefinition } from "./api/mesh.ts";
import { OverlayServerDeviceGroupDefinition, OverlayServersGroupDefinition } from "./api/overlay-servers.ts";
import { MeshNetworkGroupDefinition } from "./api/mesh-network.ts";
import { InitialVmNetwork, InitialVmNetworkReceipt } from "./api/initial-network.ts";
import { ReplaceVmHttpsProxyRequest, VmHttpsProxyReceipt } from "./api/https-proxies.ts";
import { VmImage, VmImageList, VmImageSelection } from "./api/images.ts";
import { VmCreationKey } from "./lib/ids.ts";
import { CreatedByCaller } from "./api/common.ts";
import { VmInstanceIdentity, VmInstanceIdentityQuery } from "./api/instance-identity.ts";
import { DomainsGroupDefinition, TlsForwardAuthGroupDefinition, TlsRulesGroupDefinition } from "./api/domains.ts";
import { GuestPath } from "./api/guest-path.ts";
import {
  abortFileUploadEndpoint,
  beginFileUploadEndpoint,
  commitFileUploadEndpoint,
  getFileUploadEndpoint,
  makeDirectoryEndpoint,
  pathExistsEndpoint,
  removePathEndpoint,
  uploadFileChunkEndpoint,
} from "./api/file-ops.ts";

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

export const VmState = Schema.Literal("starting", "running", "pausing", "paused", "stopped", "unknown").annotations({
  description:
    "starting: booting. running: up. pausing/paused: frozen with memory kept; resume continues it exactly. stopped: shut down, disk kept, memory gone; start boots it again. unknown: a state this API version does not name.",
});
export type VmState = typeof VmState.Type;

const IDLE_DEFINITION =
  "Seconds without network activity before the VM pauses itself (memory kept; start or resume continues it). Only network traffic to or from the VM counts as activity: CPU work and disk I/O alone do not keep it awake. A long job without traffic needs -1 or a larger value. -1 never pauses for idleness.";

/** Label keys and values: short, printable, safe in URLs. */
const LABEL_KEY = /^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?$/u;
const LabelValue = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9._:/@-]{0,63}$/));
export const MAX_LABELS = 16;
// Record key schemas only drop keys that do not match, so keys are checked by a filter that rejects.
export const Labels = Schema.Record({ key: Schema.String, value: LabelValue })
  .pipe(
    Schema.filter((labels) => Object.keys(labels).length <= MAX_LABELS && Object.keys(labels).every((key) => LABEL_KEY.test(key)), {
      message: () => `at most ${MAX_LABELS} labels, keys of lowercase letters, digits and . _ / -`,
    }),
  )
  .annotations({
    identifier: "Labels",
    description: `Up to ${MAX_LABELS} key/value labels for finding VMs (list filters by them). Keys: lowercase letters, digits and . _ / - (1-63 characters); values: letters, digits and . _ : / @ - (0-63 characters). Stored by cmux, not secret.`,
  });

export const VmResources = Schema.Struct({
  vcpus: Schema.Number,
  memoryMib: Schema.Number,
  diskMib: Schema.Number,
}).annotations({ identifier: "VmResources" });

export class Vm extends Schema.Class<Vm>("Vm")({
  id: VmId,
  displayName: Schema.NullOr(Schema.String).annotations({ description: "The name given at create or fork; null when none was given." }),
  labels: Labels,
  state: VmState,
  resources: VmResources,
  idleTimeoutSeconds: Schema.NullOr(Schema.Number).annotations({ description: IDLE_DEFINITION }),
  maxRunSeconds: Schema.NullOr(Schema.Number).annotations({
    description: "Pauses the VM once a single run lasts this long; each start resets it. Null: no cap.",
  }),
  autoDeleteSeconds: Schema.NullOr(Schema.Number).annotations({
    description: "Deletes the VM once it has gone this long without running; each start resets the clock. Null: never.",
  }),
  createdAt: Schema.String,
  updatedAt: Schema.String,
  creation: Schema.optional(Schema.Literal("pending")).annotations({
    description: "Present while the create that made this VM has not finished: the VM could not be grown to the requested size. Retry that create with its Idempotency-Key or creationKey to finish it, or delete the VM.",
  }),
}) {}

export class CreatedVm extends Vm.extend<CreatedVm>("CreatedVm")({
  creationKey: Schema.optional(VmCreationKey),
  initialNetwork: Schema.optional(InitialVmNetworkReceipt),
  bootImage: Schema.optional(VmImage),
}) {}

export class VmList extends Schema.Class<VmList>("VmList")({
  items: Schema.Array(Vm),
  nextCursor: Schema.NullOr(Schema.String).annotations({ description: "Pass as `cursor` to read the next page; null on the last page." }),
}) {}

/** An explicit receipt: a paused VM alone is not fenced against inbound wake. */
export class RetiredVm extends Schema.Class<RetiredVm>("RetiredVm")({
  id: VmId,
  state: Schema.Literal("paused", "stopped"),
  retired: Schema.Literal(true),
}) {}

const IdleTimeoutSeconds = Schema.Int.pipe(Schema.between(-1, 7 * 24 * 60 * 60)).annotations({
  description: `${IDLE_DEFINITION} Dev/test tenants: 1 to 300, default 300. Other tenants: default -1 (the cmux app pauses product machines itself).`,
});
const DisplayName = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100));
const MaxRunSeconds = Schema.Int.pipe(Schema.between(-1, 30 * 24 * 60 * 60)).annotations({
  description: "Pause the VM once a single run has lasted this many seconds, however busy it is; each start gives a fresh budget. -1 or omitted: no cap.",
});
const AutoDeleteSeconds = Schema.Int.pipe(Schema.between(-1, 365 * 24 * 60 * 60)).annotations({
  description:
    "Delete the VM once it has gone this many seconds without running; each start resets the clock, and a running VM is never deleted for this. 0 deletes it as soon as it stops. -1 or omitted: never.",
});

export const BASE_IMAGE_DESCRIPTION =
  "Without snapshotId or image the VM boots the cmux base image, Ubuntu 24.04 LTS, with 4 vCPUs, 8192 MiB memory and 32768 MiB disk unless resources says otherwise.";

export const RequestedResources = Schema.Struct({
  vcpus: Schema.optional(Schema.Int.pipe(Schema.between(2, 32))),
  memoryMib: Schema.optional(Schema.Int.pipe(Schema.between(4096, 65536))),
  diskMib: Schema.optional(Schema.Int.pipe(Schema.between(16384, 131072))),
}).annotations({
  identifier: "RequestedResources",
  description:
    "Size of the new VM. Omitted axes keep the base image's size. The VM boots from the largest base size that fits within the request on every axis, then grows to the exact request. Growing is a second step after the create and is not atomic. A failed or unconfirmed grow retains the allocation and quota; inspect or retry the same creation intent, or cancel it. The error is 503, or 429 for capacity. Sizes can only grow, so a VM booted from a snapshot cannot be made smaller than the snapshot.",
});

/** Requested values are resource floors, so a retry never shrinks a VM. */
export class ResizeVmRequest extends Schema.Class<ResizeVmRequest>("ResizeVmRequest")({
  resources: RequestedResources.pipe(Schema.filter((value) => Object.values(value).some((axis) => axis !== undefined), {
    message: () => "Specify at least one resource axis",
    jsonSchema: { minProperties: 1 },
  })).annotations({ identifier: "ResizeVmResources", description: "Nonempty minimum resource floors. Omitted axes stay unchanged and larger axes are retained.", parseOptions: { onExcessProperty: "error" } }),
}, {
  parseOptions: { onExcessProperty: "error" },
  description: "Grow an existing VM to at least the requested resources. Omitted axes stay unchanged; already larger axes are kept. Disk growth requires a running VM.",
  message: () => ({ message: "Invalid VM resize request", override: true }),
}) {}

export class CreateVmRequest extends Schema.Class<CreateVmRequest>("CreateVmRequest")(
  {
    image: Schema.optionalWith(VmImageSelection, { exact: true }),
    // An undefined union branch would echo invalid proxy credentials in decode errors.
    initialNetwork: Schema.optionalWith(InitialVmNetwork, { exact: true }),
    displayName: Schema.optional(DisplayName),
    snapshotId: Schema.optional(SnapshotId.annotations({ description: "Boot from one of the tenant's snapshots; mutually exclusive with image. Omit both for the base image." })),
    resources: Schema.optional(RequestedResources),
    idleTimeoutSeconds: Schema.optional(IdleTimeoutSeconds),
    maxRunSeconds: Schema.optional(MaxRunSeconds),
    autoDeleteSeconds: Schema.optional(AutoDeleteSeconds),
    labels: Schema.optional(Labels),
  },
  {
    description: BASE_IMAGE_DESCRIPTION,
    message: () => ({ message: "Invalid VM creation request", override: true }),
  },
) {}

export class ForkVmRequest extends Schema.Class<ForkVmRequest>("ForkVmRequest")({
  displayName: Schema.optional(DisplayName),
  idleTimeoutSeconds: Schema.optional(IdleTimeoutSeconds),
  maxRunSeconds: Schema.optional(MaxRunSeconds),
  autoDeleteSeconds: Schema.optional(AutoDeleteSeconds),
  labels: Schema.optional(Labels.annotations({ description: "Labels for the new VM; the source's labels are not copied." })),
}) {}

/** cx-b4h.2: only what the tenant may change; ownership, provider naming and the lifetime budget are not fields. */
export class UpdateVmRequest extends Schema.Class<UpdateVmRequest>("UpdateVmRequest")({
  displayName: Schema.optional(Schema.NullOr(DisplayName).annotations({ description: "A new name; null clears it." })),
  labels: Schema.optional(Labels.annotations({
    description: "Replaces the VM's whole label set. Labels whose key starts with cmux. are managed by cmux and must keep their current values; a service or agent key must keep the labels it is limited to.",
  })),
  idleTimeoutSeconds: Schema.optional(IdleTimeoutSeconds),
  maxRunSeconds: Schema.optional(MaxRunSeconds),
  autoDeleteSeconds: Schema.optional(AutoDeleteSeconds),
}, {
  parseOptions: { onExcessProperty: "error" },
  description: "Change a VM's name, labels or limits. Omitted fields stay as they are; at least one is required. Any other field (slug, metadata, the lifetime run budget) is refused with 400.",
  message: () => ({ message: "Invalid VM update request", override: true }),
}) {}

/** `key=value`: keeps VMs whose label `key` equals `value`. */
const LabelSelector = Schema.String.pipe(Schema.pattern(/^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?=[A-Za-z0-9._:/@-]{0,63}$/));

export const ListVmsParams = Schema.Struct({
  createdBy: Schema.optional(CreatedByCaller),
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 100))),
  cursor: Schema.optional(Schema.String.pipe(Schema.maxLength(512))),
  state: Schema.optional(VmState.annotations({
    description: "Keeps only VMs in this state. A filtered page can hold fewer than `limit` items; follow `nextCursor`.",
  })),
  label: Schema.optional(Schema.Array(LabelSelector).pipe(Schema.maxItems(MAX_LABELS)).annotations({
    description: "`key=value`; repeat for several. Keeps only VMs that carry every given label.",
  })),
});

export { GuestPath };

/** POSIX environment variable names; a filter so a bad name is rejected, not dropped. */
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/u;
const Env = Schema.Record({ key: Schema.String, value: Schema.String.pipe(Schema.maxLength(32 * 1024)) }).pipe(
  Schema.filter((env) => Object.keys(env).length <= 128 && Object.keys(env).every((key) => ENV_NAME.test(key)), {
    message: () => "at most 128 variables with POSIX names",
  }),
);

export class ExecRequest extends Schema.Class<ExecRequest>("ExecRequest")({
  command: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(64 * 1024)).annotations({
    description: "The command line, run by the guest's shell. Never recorded in the audit log.",
  }),
  env: Schema.optional(Env.annotations({
    description: "Extra environment variables; names are POSIX ([A-Za-z_][A-Za-z0-9_]*).",
  })),
  stdinBase64: Schema.optional(
    Schema.String.pipe(Schema.maxLength(1_398_104), Schema.pattern(/^[A-Za-z0-9+/]*={0,2}$/)).annotations({
      description: "Standard input, base64, at most 1 MiB decoded.",
    }),
  ),
  timeoutMs: Schema.optional(Schema.Int.pipe(Schema.between(1, 300_000)).annotations({
    description: "Wall-clock limit in milliseconds, 1 to 300000 (5 minutes); default 30000. The command is killed at the deadline and exitCode is null.",
  })),
  linuxUser: Schema.optional(Schema.String.pipe(Schema.pattern(/^[a-z_][a-z0-9_-]{0,31}$/)).annotations({
    description: "Guest Linux user to run as; default is the image's default user.",
  })),
}) {}

export class ExecResult extends Schema.Class<ExecResult>("ExecResult")({
  exitCode: Schema.NullOr(Schema.Int).annotations({ description: "Exit status; null when the command was killed by its timeout." }),
  stdout: Schema.String,
  stderr: Schema.String,
}) {}

export const FileEntryKind = Schema.Literal("file", "directory", "symlink", "other");
export type FileEntryKind = typeof FileEntryKind.Type;

export class FileEntry extends Schema.Class<FileEntry>("FileEntry")({
  name: Schema.String,
  kind: FileEntryKind,
}) {}

export class FileList extends Schema.Class<FileList>("FileList")({
  entries: Schema.Array(FileEntry),
}) {}

export class FileStat extends Schema.Class<FileStat>("FileStat")({
  kind: FileEntryKind,
  size: Schema.Int.pipe(Schema.between(0, Number.MAX_SAFE_INTEGER)),
  mode: Schema.Int.pipe(Schema.between(0, 0o7777)).annotations({ description: "POSIX permission bits, including setuid/setgid/sticky, as an integer (420 is 0644). File-type bits are excluded." }),
  mtime: Schema.NullOr(Schema.Int.pipe(Schema.between(-62167219200, 253402300799))).annotations({ description: "Last modification time, epoch seconds. Null when unavailable on the saved disk; never inferred from the VM's timestamps." }),
  owner: Schema.String.pipe(Schema.maxLength(256)),
  group: Schema.String.pipe(Schema.maxLength(256)),
}) {}

export const FilePathParams = Schema.Struct({ path: GuestPath });

export const WriteFileParams = Schema.Struct({
  path: GuestPath,
  mode: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(0, 0o7777)).annotations({
    description: "Final permission bits as a decimal integer, e.g. 493 for 0755 (an executable). Default: the existing file's mode, or 0600 for a new file.",
  })),
});

/** With a session token, names the team (tenant) the request acts for. Ignored for API keys. */
const teamHeader = { "x-cmux-team-id": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128))) };

export const TeamHeaders = Schema.Struct(teamHeader);

export const ReadFileHeaders = Schema.Struct({
  ...teamHeader,
  /** One byte range, e.g. `bytes=0-1048575`; the answer is then 206 with Content-Range. */
  range: Schema.optional(Schema.String.pipe(Schema.pattern(/^bytes=\d{1,19}-\d{0,19}$/))),
});

export const WriteFileHeaders = Schema.Struct({
  ...teamHeader,
  /** Required: the exact upload size in bytes. */
  "content-length": Schema.optional(Schema.String.pipe(Schema.pattern(/^\d{1,19}$/))),
});

/** Retrying a create with the same idempotency key returns the first result instead of creating twice. */
export const CreateHeaders = Schema.Struct({
  ...teamHeader,
  "idempotency-key": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(255))),
});

const VmPath = Schema.Struct({ vmId: Schema.String });

const describe = (summary: string, scope: string, details?: string) =>
  OpenApi.annotations({
    summary,
    description: `${summary}. Requires the ${scope} scope.${details === undefined ? "" : ` ${details}`} Another tenant's resource is always 404; a tenant's per-minute rate limit answers 429.`,
  });

export class Health extends Schema.Class<Health>("Health")({ ok: Schema.Literal(true) }) {}

export class HealthGroup extends HttpApiGroup.make("health").add(
  HttpApiEndpoint.get("health", "/healthz")
    .addSuccess(Health)
    .annotateContext(OpenApi.annotations({ summary: "Liveness check; no credentials needed" })),
) {}

/** A VM action that answers with the VM's new state. */
const vmAction = <const Name extends string>(endpointName: Name, path: `/v1/vms/:vmId/${string}`, summary: string, details: string) =>
  HttpApiEndpoint.post(endpointName, path)
    .setPath(VmPath)
    .setHeaders(TeamHeaders)
    .addSuccess(Vm)
    .addError(NotFound)
    .addError(Conflict)
    .addError(QuotaExceeded)
    .annotateContext(describe(summary, "vm:write", details));

export class VmsGroup extends HttpApiGroup.make("vms")
  .add(
    HttpApiEndpoint.get("getVmInstanceIdentity", "/v1/vms/:vmId/identity")
      .setPath(VmPath).setUrlParams(VmInstanceIdentityQuery).setHeaders(TeamHeaders).addSuccess(VmInstanceIdentity)
      .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("Read a VM allocation's instance fingerprint", "vm:read", "Identifies the canonical allocation without exposing its private instance ID. sha256-v1 is lowercase SHA-256 of UTF-8 cmux-vm-instance-v1, a newline, then the exact guest instance ID. Stable across power changes; a new allocation has a different fingerprint. By default this reads only the ownership record. checkPresence=true also reads provider state without waking the guest and returns present or missing; only a caller that owns the allocation can receive missing, while an inaccessible allocation remains 404. Neither result grants access. Binding still requires a guest signature, single-use nonce and current epoch.")),
  )
  .add(
    HttpApiEndpoint.post("retireVm", "/v1/vms/:vmId/retire")
      .setPath(VmPath).setHeaders(TeamHeaders).addSuccess(RetiredVm)
      .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("Retire a VM permanently", "vm:write", "Confirms a zero lifetime run budget and a paused or stopped VM. Later starts, inbound wakes, exec and file writes are refused. File reads and deletion remain available, subject to existing deletion deadlines. Syncs an already running guest first, best effort and bounded; never starts a paused guest. There is no unretire operation. Retrying is safe; 503 can mean the fence applied but its final state is unconfirmed. No active VM plan is required to retire an existing VM.")),
  )
  .add(
    HttpApiEndpoint.post("resizeVm", "/v1/vms/:vmId/resize")
      .setPath(VmPath).setHeaders(CreateHeaders).setPayload(ResizeVmRequest).addSuccess(Vm)
      .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(PaymentRequired).addError(QuotaExceeded)
      .annotateContext(describe("Grow a VM", "vm:write", "Requires the tenant's VM plan. Requested axes are minimums: larger values are retained, never shrunk. Disk growth requires a running VM. The API confirms resource floors before success, including after a failed provider response. A retry with the same Idempotency-Key replays the current VM; changed resource intent is 409. A partial failure can leave grown resources; no VM is deleted.")),
  )
  .add(
    HttpApiEndpoint.get("listVmImages", "/v1/vm-images").setHeaders(TeamHeaders).addSuccess(VmImageList)
      .addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("List approved VM images", "vm:read", "Returns only image descriptors approved for the authenticated service. Provider snapshot references are not exposed. An ordinary tenant credential sees an empty catalog.")),
  )
  .add(
    HttpApiEndpoint.post("createVm", "/v1/vms")
      .setPayload(CreateVmRequest)
      .setHeaders(CreateHeaders)
      .addSuccess(CreatedVm, { status: 201 })
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Create a VM",
          "vm:write",
          "Refused with 402 when the tenant's plan does not include VMs and 429 at the tenant's VM quota. Dev/test tenants may not ask for an idle timeout over 300 seconds and default to 300; other tenants default to -1 (never pause for idleness). When no Idempotency-Key is supplied, the API issues a public creationKey and journals the allocation. Save this handle and use it as Idempotency-Key for retries; a separate request without a key is a new intent. GET /v1/vm-creations can recover a lost server-issued handle. Unconfirmed allocations retain quota until reconciliation or verified cancellation. Server-issued handles never expire into permission to allocate again. A retry with the same Idempotency-Key returns the first VM instead of creating another; the same key with a different body is 409. Keys with a resource allowlist cannot create. initialNetwork additionally requires vm:network; proxy destinations must be enabled by the deployment. When initialNetwork is requested, its receipt confirms the accepted policy. A missing receipt means the API does not support that request; do not assume the policy was applied.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listVms", "/v1/vms")
      .setUrlParams(ListVmsParams)
      .setHeaders(TeamHeaders)
      .addSuccess(VmList)
      .addError(BadRequest)
      .addError(QuotaExceeded)
      .annotateContext(describe("List the tenant's VMs, newest first", "vm:read", "A key with a resource allowlist sees only those VMs.")),
  )
  .add(
    HttpApiEndpoint.put("replaceVmHttpsProxy", "/v1/vms/:vmId/https-proxies/:hostname")
      .setPath(Schema.Struct({ vmId: Schema.String, hostname: Schema.String }))
      .setPayload(ReplaceVmHttpsProxyRequest)
      .setHeaders(CreateHeaders)
      .addSuccess(VmHttpsProxyReceipt)
      .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("Replace an HTTPS proxy", "vm:network",
        "Replaces only an existing HTTP proxy whose source is exactly this VM, never a shared-network or public rule. The destination must be approved by the deployment. Missing rules are 404; multiple matches are 409. Credentials are write-only. With an Idempotency-Key, identical retries replay the receipt; changed policy or credentials are 409. This does not install guest hosts entries or create new proxy rules.")),
  )
  .add(
    HttpApiEndpoint.patch("updateVm", "/v1/vms/:vmId")
      .setPath(VmPath).setHeaders(TeamHeaders).setPayload(UpdateVmRequest).addSuccess(Vm)
      .addError(BadRequest).addError(Forbidden).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("Update a VM's name, labels or limits", "vm:write", "Name and labels are stored by cmux; idleTimeoutSeconds, maxRunSeconds and autoDeleteSeconds are applied to the VM (-1 removes a limit; dev/test tenants keep the 1 to 300 second idle rule). Labels replace the whole set; labels starting with cmux. cannot be added, removed or changed, and a service or agent key cannot drop the labels it is limited to (403). The provider's slug, metadata, tenant tagging and the lifetime run budget (which keeps a retired VM retired) cannot be changed. A VM whose create has not finished is 409, and so is a concurrent change of its name or labels (read and retry). Audited.")),
  )
  .add(
    HttpApiEndpoint.get("getVm", "/v1/vms/:vmId")
      .setPath(VmPath)
      .setHeaders(TeamHeaders)
      .addSuccess(Vm)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a VM", "vm:read")),
  )
  .add(vmAction("startVm", "/v1/vms/:vmId/start", "Start a VM", "Boots a stopped VM, or resumes a paused one exactly where it was (on a paused VM, start and resume do the same thing)."))
  .add(
    vmAction(
      "stopVm",
      "/v1/vms/:vmId/stop",
      "Stop a running VM",
      "Shuts the guest down from inside (memory is discarded, the disk is kept); start boots it again. Stopping a stopped VM changes nothing; a paused or starting VM is 409. The answer can still say running while the guest shuts down; read the VM until it says stopped.",
    ),
  )
  .add(vmAction("pauseVm", "/v1/vms/:vmId/pause", "Pause a running VM", "Freezes the VM with its memory kept; resume or start continues it exactly. A VM that is not running is 409."))
  .add(
    vmAction(
      "resumeVm",
      "/v1/vms/:vmId/resume",
      "Resume a paused VM",
      "Resume is start of a paused VM: it continues exactly where the pause left it. A VM that is not paused is 409; use start to boot a stopped VM.",
    ),
  )
  .add(
    HttpApiEndpoint.post("forkVm", "/v1/vms/:vmId/fork")
      .setPath(VmPath)
      .setPayload(ForkVmRequest)
      .setHeaders(CreateHeaders)
      .addSuccess(CreatedVm, { status: 201 })
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .addError(ForkIncomplete)
      .annotateContext(
        describe(
          "Fork a VM into a new VM with the same memory and disk",
          "vm:write",
          "Fork is a snapshot of the source followed by a create from that snapshot, so it costs more than a create and is not atomic. A fresh source must be running or paused (409 otherwise); a retained snapshot or destination can be recovered after source deletion. On success the intermediate snapshot is deleted. If the snapshot succeeds and the create fails, the answer is 503 ForkIncomplete when allocation cannot be confirmed, with the kept snapshot's id and a server-issued creationKey when the caller omitted its key, which belongs to the caller's tenant; a retry with the same Idempotency-Key creates from that snapshot without taking a second one. Billing, quota, idle-timeout and idempotency rules are those of create.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.del("deleteVm", "/v1/vms/:vmId")
      .setPath(VmPath)
      .setHeaders(TeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(describe("Delete a VM permanently", "vm:write")),
  )
  .middleware(Authentication) {}

export class ExecGroup extends HttpApiGroup.make("exec")
  .add(
    HttpApiEndpoint.post("execVm", "/v1/vms/:vmId/exec")
      .setPath(VmPath)
      .setPayload(ExecRequest)
      .setHeaders(TeamHeaders)
      .addSuccess(ExecResult)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Run a command in a running VM and wait for it",
          "vm:exec",
          "A non-zero exit is still 200; read exitCode. The response streams as the VM sends it and is not buffered. 409 when the VM is not running or stopped answering mid-command (the command may have run; do not retry blindly). The command and its output are never audited.",
        ),
      ),
  )
  .middleware(Authentication) {}

export class FilesGroup extends HttpApiGroup.make("files")
  .add(
    HttpApiEndpoint.get("statFile", "/v1/vms/:vmId/files/stat")
      .setPath(VmPath).setUrlParams(FilePathParams).setHeaders(TeamHeaders).addSuccess(FileStat)
      .addError(BadRequest).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
      .annotateContext(describe("Read file metadata from a VM", "vm:files", "Reads metadata directly from saved disk on paused, stopped or retired VMs without starting or executing the guest. Symlinks are reported as symlinks even if their target is a file or directory. A missing path is 404 File not found. Malformed provider metadata answers 503 instead of inventing size, permissions or timestamps. The API adds no read audit row.")),
  )
  .add(
    HttpApiEndpoint.get("readFile", "/v1/vms/:vmId/files/content")
      .setPath(VmPath)
      .setUrlParams(FilePathParams)
      .setHeaders(ReadFileHeaders)
      .addSuccess(HttpApiSchema.Uint8Array())
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Read a file from a VM",
          "vm:files",
          "Streams the file's bytes. With a Range header the answer is 206 with Content-Range. A missing file is 404 \"File not found\".",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.put("writeFile", "/v1/vms/:vmId/files/content")
      .setPath(VmPath)
      .setUrlParams(WriteFileParams)
      .setHeaders(WriteFileHeaders)
      .setPayload(HttpApiSchema.Uint8Array())
      .addSuccess(HttpApiSchema.NoContent)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(PayloadTooLarge)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Write a file in a VM",
          "vm:files",
          "The body is the file's raw bytes with Content-Length set; it is streamed to the VM and replaces the file atomically. Uploads over the size limit are 413.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listFiles", "/v1/vms/:vmId/files/entries")
      .setPath(VmPath)
      .setUrlParams(FilePathParams)
      .setHeaders(TeamHeaders)
      .addSuccess(FileList)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(describe("List a directory in a VM", "vm:files")),
  )
  .add(pathExistsEndpoint)
  .add(makeDirectoryEndpoint)
  .add(removePathEndpoint)
  .add(beginFileUploadEndpoint)
  .add(getFileUploadEndpoint)
  .add(uploadFileChunkEndpoint)
  .add(commitFileUploadEndpoint)
  .add(abortFileUploadEndpoint)
  .middleware(Authentication) {}

export class CmuxVmApi extends HttpApi.make("cmux-vm")
  .add(HealthGroup)
  .add(VmsGroup)
  .add(VmCreationsGroupDefinition.middleware(Authentication))
  .add(ExecGroup)
  .add(FilesGroup)
  .add(SnapshotsGroupDefinition.middleware(Authentication))
  .add(TerminalsGroupDefinition.middleware(Authentication))
  .add(ApiKeysGroupDefinition.middleware(Authentication))
  .add(AgentsGroupDefinition.middleware(Authentication))
  .add(ClientSessionsGroupDefinition.middleware(Authentication))
  .add(MeshGroupDefinition.middleware(Authentication))
  // No credential: a one-time enrollment code authorizes the call (mesh M2, cx-0op.4).
  .add(MeshEnrollGroupDefinition)
  // No credential: the device's install-key signature authorizes its own reads and rotation (mesh M3, cx-0op.5).
  .add(MeshDeviceGroupDefinition)
  .add(OverlayServersGroupDefinition.middleware(Authentication))
  .add(OverlayServerDeviceGroupDefinition)
  .add(MeshNetworkGroupDefinition.middleware(Authentication))
  // Domains and TLS (cx-b4h.6).
  .add(DomainsGroupDefinition.middleware(Authentication))
  .add(TlsRulesGroupDefinition.middleware(Authentication))
  .add(TlsForwardAuthGroupDefinition.middleware(Authentication))
  .annotateContext(
    OpenApi.annotations({
      title: "cmux VM API",
      version: "0.1.0",
      description: "Tenant-scoped virtual machines for cmux.",
      servers: [{ url: "https://vm.cmux.dev", description: "Production" }, { url: "https://vm-staging.cmux.dev", description: "Staging" }],
    }),
  ) {}
