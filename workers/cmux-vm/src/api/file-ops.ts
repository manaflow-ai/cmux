/**
 * More of the /v1/vms/{vmId}/files family: exists, mkdir, remove and resumable
 * uploads (cx-b4h.2). src/api.ts adds these endpoints to its `files` group, so
 * they share its Authentication middleware, the vm:files scope and the guest
 * path rule (src/api/guest-path.ts) of read, write, list and stat. This module
 * never imports src/api.ts.
 */
import { HttpApiEndpoint, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, NotFound, PayloadTooLarge, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { GuestPath } from "./guest-path.ts";

/** The provider's ceiling for one uploaded file: 16 GiB. A deployment can set a lower one. */
export const MAX_RESUMABLE_UPLOAD_BYTES = 16 * 1024 * 1024 * 1024;
/** The provider's ceiling for one chunk: 256 MiB. The tenant's upload limit usually keeps chunks smaller. */
export const PROVIDER_MAX_CHUNK_BYTES = 256 * 1024 * 1024;

const teamHeader = { "x-cmux-team-id": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128))) };
const TeamHeaders = Schema.Struct(teamHeader);
const VmPath = Schema.Struct({ vmId: Schema.String });
const UploadPath = Schema.Struct({ vmId: Schema.String, uploadId: Schema.String });
const PathParams = Schema.Struct({ path: GuestPath });

const describe = (summary: string, details: string) =>
  OpenApi.annotations({
    summary,
    description: `${summary}. Requires the vm:files scope. ${details} Another tenant's resource is always 404; a tenant's per-minute rate limit answers 429.`,
  });

const ByteCount = Schema.Int.pipe(Schema.between(0, MAX_RESUMABLE_UPLOAD_BYTES));

export class PathExists extends Schema.Class<PathExists>("PathExists")({
  exists: Schema.Boolean,
}) {}

export class MakeDirectoryRequest extends Schema.Class<MakeDirectoryRequest>("MakeDirectoryRequest")({
  path: GuestPath,
}, { parseOptions: { onExcessProperty: "error" } }) {}

export class BeginFileUploadRequest extends Schema.Class<BeginFileUploadRequest>("BeginFileUploadRequest")({
  path: GuestPath.annotations({ description: "Absolute path the finished file is committed to." }),
  size: ByteCount.annotations({ description: "The whole file's size in bytes, up to the deployment's resumable upload limit (at most 16 GiB)." }),
  sha256: Schema.optional(Schema.String.pipe(Schema.pattern(/^[0-9a-fA-F]{64}$/)).annotations({
    description: "SHA-256 of the whole file, 64 hex characters. Commit fails with 400 when the received bytes do not match.",
  })),
  mode: Schema.optional(Schema.Int.pipe(Schema.between(0, 0o7777)).annotations({
    description: "Final permission bits as a decimal integer, e.g. 493 for 0755. Default: the existing file's mode, or 0600 for a new file.",
  })),
}, { parseOptions: { onExcessProperty: "error" } }) {}

export class FileUpload extends Schema.Class<FileUpload>("FileUpload")({
  uploadId: Schema.String.annotations({
    description: "Opaque upload handle, valid only for this VM and tenant. Sessions expire after about an hour without a chunk and do not survive a host restart (then 404: begin again).",
  }),
  path: Schema.String.annotations({ description: "Absolute guest path the file will be committed to." }),
  size: ByteCount,
  receivedBytes: ByteCount.annotations({ description: "Bytes stored so far: the offset the next chunk must start at." }),
  maxChunkBytes: Schema.Int.annotations({ description: "The largest chunk this API accepts for this tenant, in bytes." }),
}) {}

export const UploadChunkParams = Schema.Struct({
  offset: Schema.NumberFromString.pipe(Schema.int(), Schema.between(0, MAX_RESUMABLE_UPLOAD_BYTES)).annotations({
    description: "Byte offset the chunk starts at. Must equal receivedBytes; a chunk at an already received offset is acknowledged without rewriting (safe retry), and a later offset is 409.",
  }),
});

export const UploadChunkHeaders = Schema.Struct({
  ...teamHeader,
  /** Required: the chunk's exact size in bytes. */
  "content-length": Schema.optional(Schema.String.pipe(Schema.pattern(/^\d{1,19}$/))),
});

export const pathExistsEndpoint = HttpApiEndpoint.get("pathExists", "/v1/vms/:vmId/files/exists")
  .setPath(VmPath).setUrlParams(PathParams).setHeaders(TeamHeaders).addSuccess(PathExists)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Check whether a path exists in a VM", "Answers exists:false for a missing path; 404 means the VM. No audit row."));

export const makeDirectoryEndpoint = HttpApiEndpoint.post("makeDirectory", "/v1/vms/:vmId/files/directories")
  .setPath(VmPath).setPayload(MakeDirectoryRequest).setHeaders(TeamHeaders).addSuccess(HttpApiSchema.NoContent)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Create a directory in a VM", "Creates missing parent directories too (like mkdir -p); an existing directory is success. Wakes a paused VM; a retired VM is 409. Audited by action and VM, never by path."));

export const removePathEndpoint = HttpApiEndpoint.del("removePath", "/v1/vms/:vmId/files")
  .setPath(VmPath).setUrlParams(PathParams).setHeaders(TeamHeaders).addSuccess(HttpApiSchema.NoContent)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Delete a file or directory in a VM", "There is no recursive flag: the path is removed as the platform's remove does, a directory together with its contents. A missing path is 404 File not found. Wakes a paused VM; a retired VM is 409. Audited by action and VM, never by path."));

export const beginFileUploadEndpoint = HttpApiEndpoint.post("beginFileUpload", "/v1/vms/:vmId/files/uploads")
  .setPath(VmPath).setPayload(BeginFileUploadRequest).setHeaders(TeamHeaders).addSuccess(FileUpload, { status: 201 })
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(PayloadTooLarge).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Start a resumable file upload into a VM", "For files larger than one PUT /files/content allows. Send the bytes in order with PUT /files/uploads/{uploadId}?offset=N, each chunk at most maxChunkBytes, then POST .../commit. The file appears at path only on commit, atomically. A size over 16 GiB is 400; a size over a lower deployment limit is 413; too many open uploads on the VM is 409. Audited."));

export const getFileUploadEndpoint = HttpApiEndpoint.get("getFileUpload", "/v1/vms/:vmId/files/uploads/:uploadId")
  .setPath(UploadPath).setHeaders(TeamHeaders).addSuccess(FileUpload)
  .addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Read a resumable upload's progress", "After a failed chunk, resume at receivedBytes. An unknown, expired or foreign upload id is 404 Upload not found."));

export const uploadFileChunkEndpoint = HttpApiEndpoint.put("uploadFileChunk", "/v1/vms/:vmId/files/uploads/:uploadId")
  .setPath(UploadPath).setUrlParams(UploadChunkParams).setHeaders(UploadChunkHeaders).setPayload(HttpApiSchema.Uint8Array())
  .addSuccess(FileUpload)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(PayloadTooLarge).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Send one chunk of a resumable upload", "The body is the chunk's raw bytes with Content-Length set, at most maxChunkBytes (413 otherwise). A gap after receivedBytes, or an upload being committed, is 409; a chunk that overruns the declared size is 400. Chunks are not audited."));

export const commitFileUploadEndpoint = HttpApiEndpoint.post("commitFileUpload", "/v1/vms/:vmId/files/uploads/:uploadId/commit")
  .setPath(UploadPath).setHeaders(TeamHeaders).addSuccess(HttpApiSchema.NoContent)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Finish a resumable upload", "Verifies the size (and sha256 when given) and renames the file into place atomically; the target never holds a partial file. Missing bytes or a sha256 mismatch is 400 and the upload stays open, so commit can be retried. A commit already running is 409. A commit whose answer was lost (503) may still complete: a later 404 Upload not found then means it finished, so check the path. Audited (vm.files.upload.commit)."));

export const abortFileUploadEndpoint = HttpApiEndpoint.del("abortFileUpload", "/v1/vms/:vmId/files/uploads/:uploadId")
  .setPath(UploadPath).setHeaders(TeamHeaders).addSuccess(HttpApiSchema.NoContent)
  .addError(BadRequest).addError(NotFound).addError(Conflict).addError(QuotaExceeded).addError(ServiceUnavailable)
  .annotateContext(describe("Abandon a resumable upload", "Frees the stored chunks. An upload being committed is 409. Audited."));
