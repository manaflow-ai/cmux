/**
 * Reads the text under a root of a VM's saved disk through the provider's file reads (no guest code runs, so a
 * paused VM stays paused), bounded in folders, files and bytes, many reads at once. This is what the paused-read
 * replica stores, and what a search reads when there is no replica to answer it.
 */
import type { Named } from "@gdp-ts/core";
import { Effect } from "effect";
import type { VmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { UpstreamClient, type Owns, type UpstreamError } from "../upstream/client.ts";
import type { ReplicaFile } from "./match.ts";

export const WALK_BOUNDS = {
  /** Provider reads in flight at once. */
  concurrency: 16,
  folders: 2_000,
  files: 5_000,
  /** Only a file's first bytes are read and searched. */
  fileBytes: 256 * 1024,
  /** Kept under a Durable Object RPC's 32 MiB. */
  totalBytes: 16 * 1024 * 1024,
} as const;

/** Folders a search of a checkout never wants: caches and dependency trees, each larger than the code itself. */
const SKIPPED = new Set([".git", "node_modules", "target", ".cache", ".venv", "__pycache__", ".next", "dist", "build"]);

export interface WalkResult {
  readonly files: ReplicaFile[];
  readonly bytes: number;
  readonly truncated: number;
  readonly complete: boolean;
}

const join = (dir: string, name: string) => (dir.endsWith("/") ? `${dir}${name}` : `${dir}/${name}`);

/** The first `max` bytes of a stream, then cancels it. */
const firstBytes = (body: ReadableStream<Uint8Array>, max: number) =>
  Effect.promise(async () => {
    const reader = body.getReader();
    const parts: Uint8Array[] = [];
    let length = 0;
    let more = true;
    try {
      while (length < max) {
        const { done, value } = await reader.read();
        if (done) { more = false; break; }
        parts.push(value);
        length += value.byteLength;
      }
    } finally {
      await reader.cancel().catch(() => undefined);
    }
    const out = new Uint8Array(Math.min(length, max));
    let at = 0;
    for (const part of parts) {
      const take = Math.min(part.byteLength, out.byteLength - at);
      out.set(part.subarray(0, take), at);
      at += take;
      if (at >= out.byteLength) break;
    }
    return { bytes: out, cut: more || length > max };
  });

const decoder = new TextDecoder("utf-8", { fatal: false, ignoreBOM: false });

export const walkDisk = <C, R>(
  vm: Named<R, VmId>,
  proofs: { readonly owns: Owns<C, R>; readonly scope: KeyHasScope<C, "vm:files"> },
  root: string,
): Effect.Effect<WalkResult, UpstreamError, UpstreamClient> =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const files: ReplicaFile[] = [];
    let folders = 0, bytes = 0, truncated = 0, complete = true;
    let level = [root];
    while (level.length > 0) {
      if (folders + level.length > WALK_BOUNDS.folders) { complete = false; level = level.slice(0, WALK_BOUNDS.folders - folders); }
      folders += level.length;
      const listed = yield* Effect.forEach(level, (dir) =>
        upstream.listFiles(vm, proofs, dir).pipe(
          Effect.map((entries) => entries.map((entry) => ({ path: join(dir, entry.name), kind: entry.kind, name: entry.name }))),
          // The root must list; a folder below it that vanished or is unreadable is left out.
          Effect.catchAll((error) => (dir === root ? Effect.fail(error) : Effect.succeed([]))),
        ), { concurrency: WALK_BOUNDS.concurrency });
      const entries = listed.flat();
      const next: string[] = [];
      const wanted: string[] = [];
      for (const entry of entries) {
        if (entry.kind === "directory") { if (!SKIPPED.has(entry.name)) next.push(entry.path); }
        else if (entry.kind === "file") wanted.push(entry.path);
      }
      const room = WALK_BOUNDS.files - files.length;
      if (wanted.length > room) complete = false;
      const read = yield* Effect.forEach(wanted.slice(0, Math.max(0, room)), (path) =>
        upstream.readFile(vm, proofs, path, `bytes=0-${WALK_BOUNDS.fileBytes - 1}`).pipe(
          Effect.flatMap((file) => firstBytes(file.body, WALK_BOUNDS.fileBytes).pipe(
            Effect.map(({ bytes: content, cut }) => ({ path, content, cut: cut || file.status === 206 && rangeCut(file.contentRange) })),
          )),
          // An empty file answers 416 to a range; anything else unreadable is left out.
          Effect.map((r): { path: string; content: Uint8Array; cut: boolean } | null => r),
          Effect.catchAll((error) => Effect.succeed(error.status === 416 ? { path, content: new Uint8Array(0), cut: false } : null)),
        ), { concurrency: WALK_BOUNDS.concurrency });
      for (const file of read) {
        if (file === null) continue;
        if (bytes + file.content.byteLength > WALK_BOUNDS.totalBytes) { complete = false; break; }
        bytes += file.content.byteLength;
        if (file.cut) truncated += 1;
        const binary = file.content.subarray(0, 8192).includes(0);
        files.push({ path: file.path, text: binary ? null : decoder.decode(file.content) });
      }
      if (!complete && (files.length >= WALK_BOUNDS.files || bytes >= WALK_BOUNDS.totalBytes)) break;
      level = next;
    }
    return { files, bytes, truncated, complete };
  });

/** Whether a 206's Content-Range says the file runs past the bytes read. */
const rangeCut = (contentRange: string | null): boolean => {
  const match = contentRange === null ? null : /\/(\d+)$/u.exec(contentRange);
  return match?.[1] !== undefined && Number(match[1]) > WALK_BOUNDS.fileBytes;
};
