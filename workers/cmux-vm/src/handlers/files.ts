/**
 * Files in the tenant's VM: read (streamed bytes, Range supported), write
 * (the request body streamed to the VM with an exact length), list. Paths are
 * validated by the API schema (absolute, no `..`, no NUL) before any upstream
 * call. Writes are audited by path-free action; contents never are.
 */
import { HttpApiBuilder, HttpServerResponse } from "@effect/platform";
import { Effect } from "effect";
import { CmuxVmApi, FileEntry, FileList, FileReplica, FileSearch, FileStat, SearchMatch, type FileEntryKind } from "../api.ts";
import { badRequest, conflict, fileNotFound, PayloadTooLarge, unavailable, vmNotFound } from "../errors.ts";
import { TenantPolicy } from "../policy.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { audited, auditableVmId, withOwnedVm } from "./common.ts";
import { searchFiles, under, type ReplicaMeta } from "../replica/match.ts";
import { ReplicaStore } from "../replica/store.ts";
import { walkDisk } from "../replica/walk.ts";
import type { UpstreamError } from "../upstream/client.ts";

const kindOf = (kind: string): FileEntryKind => (kind === "file" || kind === "directory" || kind === "symlink" ? kind : "other");

const NOT_RUNNING = "The VM is not running, or it stopped answering; retry once it runs";

const DEFAULT_SEARCH_LIMIT = 100;

/** A walk's failure is its root's: a missing folder, an unreadable one, or the provider. */
const walkError = (error: UpstreamError) =>
  error.status === 404 ? fileNotFound() : error.status === 409 ? conflict(NOT_RUNNING) : error.status === 400 ? badRequest("The path is not a readable directory") : unavailable(error);

const vmReadError = (error: UpstreamError) => (error.status === 404 ? vmNotFound() : unavailable(error));

export const filesHandlers = HttpApiBuilder.group(CmuxVmApi, "files", (handlers) =>
  handlers
    .handle("statFile", ({ path, urlParams }) =>
      withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) => Effect.gen(function* () {
        const upstream = yield* UpstreamClient;
        const stat = yield* upstream.statFile(vm, proofs, urlParams.path).pipe(Effect.mapError((error) =>
          error.status === 404 ? fileNotFound() : error.status === 400 ? badRequest("The path is not readable") : unavailable(error),
        ));
        return new FileStat(stat);
      })),
    )
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
              return unavailable(error);
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
                return unavailable(error);
              }),
            );
            return HttpServerResponse.empty({ status: 204 });
          }),
        ),
      ),
    )
    .handle("searchFiles", ({ path, urlParams }) =>
      withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const replicas = yield* ReplicaStore;
          const { path: root, query } = urlParams;
          const limit = urlParams.limit ?? DEFAULT_SEARCH_LIMIT;
          const current = yield* upstream.getVm(vm, proofs).pipe(Effect.mapError(vmReadError));
          const paused = current.state === "paused";
          if (paused) {
            // The replica answers only for the pause it was seeded in: the provider's updatedAt moves on any resume.
            const meta = yield* replicas.meta(vm.value).pipe(Effect.orElseSucceed(() => null));
            if (meta !== null && meta.marker === current.updatedAt && under(meta.root, root)) {
              const found = yield* replicas.search(vm.value, root, query, limit).pipe(Effect.option);
              if (found._tag === "Some") {
                return new FileSearch({
                  source: "replica",
                  complete: meta.complete && found.value.matches.length < limit,
                  scanned: found.value.scanned,
                  matches: found.value.matches.map((m) => new SearchMatch(m)),
                });
              }
            }
          }
          const startedAt = Date.now();
          const walk = yield* walkDisk(vm, proofs, root).pipe(Effect.mapError(walkError));
          if (paused) {
            const meta: ReplicaMeta = {
              root, marker: current.updatedAt, complete: walk.complete, files: walk.files.length, bytes: walk.bytes,
              truncated: walk.truncated, seededAtMs: startedAt,
            };
            // Best effort: a search that read the paused disk keeps it as the replica for the next one.
            yield* replicas.replace(vm.value, meta, walk.files).pipe(Effect.ignore);
          }
          const found = searchFiles(walk.files, root, query, limit);
          return new FileSearch({
            source: "disk",
            complete: walk.complete && found.matches.length < limit,
            scanned: found.scanned,
            matches: found.matches.map((m) => new SearchMatch(m)),
          });
        }),
      ),
    )
    .handle("seedFileReplica", ({ path, urlParams }) =>
      withOwnedVm(path.vmId, "vm:files", "files", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const replicas = yield* ReplicaStore;
          const current = yield* upstream.getVm(vm, proofs).pipe(Effect.mapError(vmReadError));
          if (current.state !== "paused") return yield* Effect.fail(conflict("Only a paused VM's replica can be seeded; pause it first"));
          const startedAt = Date.now();
          const walk = yield* walkDisk(vm, proofs, urlParams.path).pipe(Effect.mapError(walkError));
          const meta: ReplicaMeta = {
            root: urlParams.path, marker: current.updatedAt, complete: walk.complete, files: walk.files.length, bytes: walk.bytes,
            truncated: walk.truncated, seededAtMs: startedAt,
          };
          yield* replicas.replace(vm.value, meta, walk.files).pipe(Effect.mapError(() => unavailable("replica.replace")));
          return new FileReplica({
            root: meta.root, complete: meta.complete, files: meta.files, bytes: meta.bytes, truncated: meta.truncated,
            seedMs: Math.max(0, Date.now() - startedAt),
          });
        }),
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
              return unavailable(error);
            }),
          );
          return new FileList({
            entries: entries.map((entry) => new FileEntry({ name: entry.name, kind: kindOf(entry.kind) })),
          });
        }),
      ),
    ),
);
