/**
 * exists, mkdir, remove and resumable uploads (cx-b4h.2), wired into the
 * `files` group by handlers/files.ts. Same order and rules as the other file
 * routes: vm:files, the files rate class, ownership, and paths validated by the
 * API schema before any provider call. mkdir, remove, begin, commit and abort
 * are audited by action and VM only; paths, contents and chunks never are.
 */
import { HttpServerResponse } from "@effect/platform";
import { Effect } from "effect";
import { FileUpload, MAX_RESUMABLE_UPLOAD_BYTES, PathExists, PROVIDER_MAX_CHUNK_BYTES, type BeginFileUploadRequest } from "../api/file-ops.ts";
import { badRequest, conflict, fileNotFound, NotFound, PayloadTooLarge, unavailable, vmNotFound } from "../errors.ts";
import { TenantPolicy, type TenantPolicyService } from "../policy.ts";
import { UpstreamClient, type FileUploadRecord, type UpstreamError } from "../upstream/client.ts";
import { audited, auditableVmId, withOwnedVm } from "./common.ts";

const NOT_RUNNING = "The VM is not running, or it stopped answering; retry once it runs";

const uploadNotFound = () => new NotFound({ message: "Upload not found" });

const maxChunkBytes = (policy: TenantPolicyService) => Math.min(policy.maxUploadBytes, PROVIDER_MAX_CHUNK_BYTES);
const maxFileBytes = (policy: TenantPolicyService) => Math.min(policy.maxResumableUploadBytes, MAX_RESUMABLE_UPLOAD_BYTES);

const toUpload = (policy: TenantPolicyService, record: FileUploadRecord) =>
  new FileUpload({ uploadId: record.uploadId, path: record.path, size: record.size, receivedBytes: record.receivedBytes, maxChunkBytes: maxChunkBytes(policy) });

/** Provider answers on a known upload: 404 is the upload (unknown, expired or not sealed for this VM). */
const onUpload = (conflictMessage: string, badRequestMessage: string) => (error: UpstreamError) =>
  error.status === 404 ? uploadNotFound()
  : error.status === 409 ? conflict(conflictMessage)
  : error.status === 400 ? badRequest(badRequestMessage)
  : unavailable();

export const pathExists = (rawId: string, path: string) =>
  withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      const exists = yield* upstream.pathExists(vm, proofs, path).pipe(Effect.mapError((error) =>
        error.status === 404 ? vmNotFound() : error.status === 409 ? conflict(NOT_RUNNING) : error.status === 400 ? badRequest("The path is not readable") : unavailable(),
      ));
      return new PathExists({ exists });
    }),
  );

export const makeDirectory = (rawId: string, path: string) =>
  audited("vm.files.mkdir", auditableVmId(rawId), withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      yield* upstream.makeDirectory(vm, proofs, path).pipe(Effect.mapError((error) =>
        error.status === 404 ? vmNotFound() : error.status === 409 ? conflict(NOT_RUNNING) : error.status === 400 ? badRequest("The directory could not be created at that path") : unavailable(),
      ));
    }),
  ));

export const removePath = (rawId: string, path: string) =>
  audited("vm.files.remove", auditableVmId(rawId), withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      // Ownership was proven just now, so a provider 404 is the path.
      yield* upstream.removePath(vm, proofs, path).pipe(Effect.mapError((error) =>
        error.status === 404 ? fileNotFound() : error.status === 409 ? conflict(NOT_RUNNING) : error.status === 400 ? badRequest("The path could not be removed") : unavailable(),
      ));
    }),
  ));

export const beginFileUpload = (rawId: string, payload: BeginFileUploadRequest) =>
  audited("vm.files.upload.begin", auditableVmId(rawId), withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const policy = yield* TenantPolicy;
      const limit = maxFileBytes(policy);
      if (payload.size > limit) {
        return yield* Effect.fail(new PayloadTooLarge({ message: `Resumable uploads are limited to ${limit} bytes`, maxBytes: limit }));
      }
      const upstream = yield* UpstreamClient;
      const record = yield* upstream.beginUpload(vm, proofs, {
        path: payload.path,
        size: payload.size,
        ...(payload.sha256 === undefined ? {} : { sha256: payload.sha256 }),
        ...(payload.mode === undefined ? {} : { mode: payload.mode }),
      }).pipe(Effect.mapError((error) =>
        error.status === 404 ? vmNotFound()
        : error.status === 409 ? conflict("Too many uploads are open on this VM, or it is not running; finish or abort one, or retry once it runs")
        : error.status === 400 ? badRequest("The upload could not be started at that path")
        : unavailable(),
      ));
      return toUpload(policy, record);
    }),
  ));

export const getFileUpload = (rawId: string, uploadId: string) =>
  withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const policy = yield* TenantPolicy;
      const upstream = yield* UpstreamClient;
      const record = yield* upstream.uploadStatus(vm, proofs, uploadId).pipe(Effect.mapError((error) =>
        error.status === 404 ? uploadNotFound() : error.status === 409 ? conflict(NOT_RUNNING) : unavailable(),
      ));
      return toUpload(policy, record);
    }),
  );

export const uploadFileChunk = (
  rawId: string,
  uploadId: string,
  offset: number,
  declaredLength: string | undefined,
  source: unknown,
) =>
  withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const policy = yield* TenantPolicy;
      const limit = maxChunkBytes(policy);
      if (declaredLength === undefined) return yield* Effect.fail(badRequest("Content-Length is required"));
      const length = Number(declaredLength);
      if (!Number.isSafeInteger(length) || length < 1) return yield* Effect.fail(badRequest("Content-Length must be a positive byte count"));
      if (length > limit) return yield* Effect.fail(new PayloadTooLarge({ message: `Upload chunks are limited to ${limit} bytes`, maxBytes: limit }));
      const body = source instanceof Request && source.body !== null ? source.body : new Blob([]).stream();
      const upstream = yield* UpstreamClient;
      const record = yield* upstream.uploadChunk(vm, proofs, uploadId, { offset, body, length }).pipe(Effect.mapError((error) =>
        error.status === 413
          ? new PayloadTooLarge({ message: `Upload chunks are limited to ${limit} bytes`, maxBytes: limit })
          : onUpload("The offset is past receivedBytes, or the upload is being committed; read its status and resume", "The chunk runs past the upload's declared size")(error),
      ));
      return HttpServerResponse.unsafeJson(toUpload(policy, record));
    }),
  );

export const commitFileUpload = (rawId: string, uploadId: string) =>
  audited("vm.files.upload.commit", auditableVmId(rawId), withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      yield* upstream.commitUpload(vm, proofs, uploadId).pipe(Effect.mapError(onUpload(
        "A commit of this upload is already running",
        "Not every byte has arrived, or the sha256 does not match; the upload is still open",
      )));
    }),
  ));

export const abortFileUpload = (rawId: string, uploadId: string) =>
  audited("vm.files.upload.abort", auditableVmId(rawId), withOwnedVm(rawId, "vm:files", "files", (_caller, vm, proofs) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      yield* upstream.abortUpload(vm, proofs, uploadId).pipe(Effect.mapError(onUpload("The upload is being committed and cannot be abandoned", "The upload could not be abandoned")));
    }),
  ));
