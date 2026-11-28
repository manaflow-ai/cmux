/**
 * Files in the tenant's VM: read (streamed bytes, Range supported), write
 * (the request body streamed to the VM with an exact length), list. Paths are
 * validated by the API schema (absolute, no `..`, no NUL) before any upstream
 * call. Writes are audited by path-free action; contents never are.
 */
import { HttpApiBuilder, HttpServerResponse } from "@effect/platform";
import { Effect } from "effect";
import { CmuxVmApi, FileEntry, FileList, type FileEntryKind } from "../api.ts";
import { badRequest, conflict, fileNotFound, PayloadTooLarge, unavailable, vmNotFound } from "../errors.ts";
import { TenantPolicy } from "../policy.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { audited, auditableVmId, withOwnedVm } from "./common.ts";

const kindOf = (kind: string): FileEntryKind => (kind === "file" || kind === "directory" || kind === "symlink" ? kind : "other");

const NOT_RUNNING = "The VM is not running, or it stopped answering; retry once it runs";

export const filesHandlers = HttpApiBuilder.group(CmuxVmApi, "files", (handlers) =>
  handlers
    .handle("readFile", ({ path, urlParams, headers }) =>
      withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const file = yield* upstream.readFile(vm, proofs, urlParams.path, headers.range).pipe(
            Effect.mapError((error) => {
              if (error.status === 404) return fileNotFound();
              if (error.status === 409) return conflict(NOT_RUNNING);
              if (error.status === 400) return badRequest("The path is not readable");
              if (error.status === 416) return badRequest("The range lies outside the file");
              return unavailable();
            }),
          );
          const responseHeaders: Record<string, string> = {};
          if (file.contentRange !== null) responseHeaders["content-range"] = file.contentRange;
          if (file.contentLength !== null) responseHeaders["content-length"] = file.contentLength;
          return HttpServerResponse.raw(file.body, {
            status: file.status,
            contentType: "application/octet-stream",
            headers: responseHeaders,
          });
        }),
      ),
    )
    .handleRaw("writeFile", ({ path, urlParams, headers, request }) =>
      audited(
        "vm.files.write",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const policy = yield* TenantPolicy;
            const declared = headers["content-length"];
            if (declared === undefined) return yield* Effect.fail(badRequest("Content-Length is required"));
            const length = Number(declared);
            if (!Number.isSafeInteger(length)) return yield* Effect.fail(badRequest("Content-Length is not valid"));
            if (length > policy.maxUploadBytes) {
              return yield* Effect.fail(
                new PayloadTooLarge({ message: `Uploads are limited to ${policy.maxUploadBytes} bytes`, maxBytes: policy.maxUploadBytes }),
              );
            }
            const source = request.source;
            const body = source instanceof Request && source.body !== null ? source.body : new Blob([]).stream();
            const upstream = yield* UpstreamClient;
            yield* upstream.writeFile(vm, proofs, { path: urlParams.path, mode: urlParams.mode, body, length }).pipe(
              Effect.mapError((error) => {
                if (error.status === 404) return vmNotFound();
                if (error.status === 409) return conflict(NOT_RUNNING);
                if (error.status === 400) return badRequest("The file could not be written at that path");
                if (error.status === 413) {
                  return new PayloadTooLarge({ message: `Uploads are limited to ${policy.maxUploadBytes} bytes`, maxBytes: policy.maxUploadBytes });
                }
                return unavailable();
              }),
            );
            return HttpServerResponse.empty({ status: 204 });
          }),
        ),
      ),
    )
    .handle("listFiles", ({ path, urlParams }) =>
      withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const entries = yield* upstream.listFiles(vm, proofs, urlParams.path).pipe(
            Effect.mapError((error) => {
              if (error.status === 404) return fileNotFound();
              if (error.status === 409) return conflict(NOT_RUNNING);
              if (error.status === 400) return badRequest("The path is not a readable directory");
              return unavailable();
            }),
          );
          return new FileList({
            entries: entries.map((entry) => new FileEntry({ name: entry.name, kind: kindOf(entry.kind) })),
          });
        }),
      ),
    ),
);
