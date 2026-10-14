// File uploads from the phone (PROTOCOL.md §3 fileChunk, §4 files): a photo,
// camera shot or file attached in the terminal composer streams to the host
// in binary chunks on the bulk lane and is written under
// ~/.cmux-next-host/uploads/<uuid>/<name>; its absolute path goes back to the
// phone, which types it into the terminal. Uploads older than 7 days are
// removed at startup and daily.

import { randomUUID } from "node:crypto";
import { mkdir, open, readdir, rename, rm, stat, type FileHandle } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { RpcError, type ClientSession, type RpcServer, type StreamSink, num, optStr, str } from "../rpc/index.ts";

/** Largest upload. */
export const UPLOAD_MAX_BYTES = 50 * 1024 * 1024;
/** An upload with no chunk for this long fails. */
export const UPLOAD_IDLE_MS = 30_000;
/** Uploads are kept this long. */
export const UPLOAD_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

export interface FilesOptions {
  /** Upload root (default ~/.cmux-next-host/uploads). */
  root?: string;
  maxBytes?: number;
  idleMs?: number;
  retentionMs?: number;
  /** Run the retention sweep at startup and daily (default true). */
  sweep?: boolean;
  log?: (msg: string) => void;
}

/**
 * A safe single path component: no directories, no control characters, no
 * leading dots, at most 120 characters (extension kept).
 */
export function sanitizeFileName(raw: string): string {
  const base = raw.split(/[\\/]/).pop() ?? "";
  let name = base
    .normalize("NFC")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[:*?"<>|]/g, "_")
    .trim()
    .replace(/^\.+/, "");
  if (name.length > 120) {
    const dot = name.lastIndexOf(".");
    const ext = dot > 0 && name.length - dot <= 16 ? name.slice(dot) : "";
    name = name.slice(0, 120 - ext.length) + ext;
  }
  return name.length > 0 ? name : "upload";
}

/** One upload in flight: chunks append to a partial file in order. */
class Upload implements StreamSink {
  readonly kind = "upload" as const;
  readonly target: string;
  private received = 0;
  private nextSeq = 0;
  private failure: string | undefined;
  private writes: Promise<unknown> = Promise.resolve();
  private finished = false;
  private waiter: (() => void) | undefined;
  private idle: NodeJS.Timeout | undefined;

  constructor(
    readonly dir: string,
    readonly name: string,
    readonly size: number,
    private readonly file: FileHandle,
    private readonly idleMs: number,
  ) {
    this.target = dir;
    this.armIdle();
  }

  get partialPath(): string {
    return join(this.dir, ".partial");
  }

  /** `[u32 BE seq][bytes]` */
  onInput(payload: Uint8Array): void {
    if (this.failure || this.finished) return;
    if (payload.byteLength < 4) return this.fail("truncated chunk");
    const seq = new DataView(payload.buffer, payload.byteOffset, 4).getUint32(0, false);
    const bytes = payload.subarray(4);
    if (seq !== this.nextSeq) return this.fail(`chunk ${seq} arrived, expected ${this.nextSeq}`);
    if (this.received + bytes.byteLength > this.size) return this.fail("more bytes than the announced size");
    this.nextSeq += 1;
    this.received += bytes.byteLength;
    const copy = Buffer.from(bytes);
    this.writes = this.writes.then(() => this.file.write(copy)).catch((e) => this.fail(`write failed: ${e}`));
    this.armIdle();
    if (this.received === this.size) this.wake();
  }

  /** Waits for every byte, then writes the file in place and returns its path. */
  async finish(): Promise<string> {
    if (this.received < this.size && !this.failure) {
      await new Promise<void>((resolve) => (this.waiter = resolve));
    }
    await this.writes;
    if (this.failure) throw new RpcError("bad_request", `upload failed: ${this.failure}`);
    this.finished = true;
    clearTimeout(this.idle);
    await this.file.close();
    const path = join(this.dir, this.name);
    await rename(this.partialPath, path);
    return path;
  }

  dispose(): void {
    clearTimeout(this.idle);
    if (this.finished) return;
    this.finished = true;
    this.fail("cancelled");
    void this.writes
      .then(() => this.file.close())
      .catch(() => {})
      .then(() => rm(this.dir, { recursive: true, force: true }));
  }

  private fail(reason: string): void {
    if (!this.failure) this.failure = reason;
    this.wake();
  }

  private wake(): void {
    const w = this.waiter;
    this.waiter = undefined;
    w?.();
  }

  private armIdle(): void {
    clearTimeout(this.idle);
    this.idle = setTimeout(() => this.fail(`no data for ${this.idleMs} ms`), this.idleMs);
    this.idle.unref?.();
  }
}

export class FilesProvider {
  readonly root: string;
  private readonly maxBytes: number;
  private readonly idleMs: number;
  private readonly retentionMs: number;
  private readonly log: (msg: string) => void;
  private sweepTimer: NodeJS.Timeout | undefined;

  constructor(opts: FilesOptions = {}) {
    this.root = opts.root ?? join(homedir(), ".cmux-next-host", "uploads");
    this.maxBytes = opts.maxBytes ?? UPLOAD_MAX_BYTES;
    this.idleMs = opts.idleMs ?? UPLOAD_IDLE_MS;
    this.retentionMs = opts.retentionMs ?? UPLOAD_RETENTION_MS;
    this.log = opts.log ?? (() => {});
    if (opts.sweep !== false) {
      void this.sweep();
      this.sweepTimer = setInterval(() => void this.sweep(), DAY_MS);
      this.sweepTimer.unref?.();
    }
  }

  private tooLarge(): RpcError {
    return new RpcError("bad_request", `file is larger than ${Math.floor(this.maxBytes / (1024 * 1024))} MB`);
  }

  /** Starts an upload; chunks arrive as fileChunk frames on the returned id. */
  async begin(session: ClientSession, name: string, size: number): Promise<number> {
    if (!Number.isInteger(size) || size < 0) throw new RpcError("bad_request", "size must be a non-negative integer");
    if (size > this.maxBytes) throw this.tooLarge();
    const dir = join(this.root, randomUUID());
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const file = await open(join(dir, ".partial"), "wx", 0o600);
    return session.addStream(new Upload(dir, sanitizeFileName(name), size, file, this.idleMs));
  }

  async end(session: ClientSession, uploadId: number): Promise<string> {
    const sink = session.streams.get(uploadId);
    if (!(sink instanceof Upload)) throw new RpcError("not_found", `no upload ${uploadId}`);
    try {
      const path = await sink.finish();
      session.streams.delete(uploadId);
      return path;
    } catch (e) {
      session.removeStream(uploadId);
      throw e;
    }
  }

  /** Removes upload folders older than the retention period. */
  async sweep(now = Date.now()): Promise<number> {
    let removed = 0;
    let entries: string[];
    try {
      entries = await readdir(this.root);
    } catch {
      return 0;
    }
    for (const entry of entries) {
      const dir = join(this.root, entry);
      try {
        const info = await stat(dir);
        if (now - info.mtimeMs > this.retentionMs) {
          await rm(dir, { recursive: true, force: true });
          removed += 1;
        }
      } catch {
        // Gone already or unreadable: skip.
      }
    }
    if (removed > 0) this.log(`removed ${removed} upload(s) older than ${Math.round(this.retentionMs / DAY_MS)} days`);
    return removed;
  }

  close(): void {
    clearInterval(this.sweepTimer);
  }

  register(server: RpcServer): void {
    server.register("fs.upload.begin", async (p, session: ClientSession) => {
      const name = str(p, "name");
      optStr(p, "mimeType");
      return { uploadId: await this.begin(session, name, num(p, "size")) };
    });
    server.register("fs.upload.end", async (p, session: ClientSession) => {
      return { path: await this.end(session, num(p, "uploadId")) };
    });
    server.register("fs.upload.cancel", (p, session: ClientSession) => {
      session.removeStream(num(p, "uploadId"));
      return {};
    });
  }
}
