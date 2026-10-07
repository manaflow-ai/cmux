import type { FreestyleClient } from "../client.js";
import type { DirEntry, FileStat } from "./types.js";
export interface ReadFileOptions {
    /** First byte to read. Default 0. */
    offset?: number;
    /** How many bytes to read. Default: to the end of the file. */
    length?: number;
    signal?: AbortSignal;
}
/**
 * How far a transfer has got. An object rather than positional arguments so it
 * can grow — a phase, a message — without breaking callers, and so progress
 * reads the same way wherever the SDK reports it.
 */
export interface TransferProgress {
    /** Bytes confirmed stored so far. */
    completedBytes: number;
    /** Bytes in the whole transfer. */
    totalBytes: number;
}
export interface WriteFileOptions {
    /** Final file mode bits, e.g. 0o755. Defaults to the target's existing mode, or 0o600. */
    mode?: number;
    /**
     * Called as bytes are confirmed stored. A chunked upload reports after each
     * chunk; a single-request write reports once, on completion.
     */
    onProgress?: (progress: TransferProgress) => void;
    signal?: AbortSignal;
    /** Bytes per chunk for large files (default 16 MiB; the server caps a chunk at 256 MiB). */
    chunkSize?: number;
    /** Attempts per chunk before giving up (default 5). */
    maxAttempts?: number;
}
/**
 * The guest filesystem of one VM: `GET/PUT /vms/{id}/fs/*`.
 *
 * Paths must be absolute, free of `..`, and at most 4096 characters. Files cross
 * the wire as raw bytes in both directions, so there is no size limit short of
 * the 16 GiB per-file ceiling and nothing to encode or decode.
 *
 * `writeFile` picks its own transport: small files go in one request, large ones
 * as a resumable chunked upload whose failed chunks are retried individually.
 * Either way the write is atomic — a reader in the guest sees the old file until
 * the new one has arrived intact — and verified by sha256 end to end.
 */
export declare class VmFilesystem {
    private readonly client;
    private readonly basePath;
    constructor(client: FreestyleClient, basePath: string);
    /**
     * Read a whole file, or with `offset`/`length` just part of one, into memory.
     *
     * The result is a plain `Uint8Array` on every runtime — never a Node
     * `Buffer`, even on Node. Don't coerce it with `String(bytes)` or
     * `bytes.toString()`: those go through the typed-array `toString` and
     * produce the byte values joined by commas ("123,10,32,…"), not the file's
     * text. For text use {@link readTextFile}, or decode explicitly with
     * `new TextDecoder().decode(bytes)`.
     */
    readFile(path: string, options?: ReadFileOptions): Promise<Uint8Array>;
    /** Read a file as UTF-8 text. Use this, not `String(await readFile(...))`. */
    readTextFile(path: string, options?: ReadFileOptions): Promise<string>;
    /**
     * Stream a file out of the VM without holding it in memory — pipe it to disk,
     * to an HTTP response, or through a parser.
     *
     * ```ts
     * const bytes = await vm.fs.readFileStream("/var/log/big.log");
     * await pipeline(Readable.fromWeb(bytes), createWriteStream("big.log"));
     * ```
     */
    readFileStream(path: string, options?: ReadFileOptions): Promise<ReadableStream<Uint8Array>>;
    /**
     * Write a file into the VM, whatever its size.
     *
     * ```ts
     * await vm.fs.writeFile("/etc/app.conf", "debug = true");
     * await vm.fs.writeFile("/data/model.bin", await openAsBlob("model.bin"), {
     *   onProgress: ({ completedBytes, totalBytes }) =>
     *     console.log(`${completedBytes}/${totalBytes}`),
     * });
     * ```
     *
     * A `Blob` (`node:fs`'s `openAsBlob`, or a browser `File`) is read one chunk at
     * a time and never held in memory whole.
     */
    writeFile(path: string, content: string | Uint8Array | Blob, options?: WriteFileOptions): Promise<void>;
    /** Write text. Identical to {@link writeFile} with a string. */
    writeTextFile(path: string, content: string, options?: WriteFileOptions): Promise<void>;
    readDir(path: string): Promise<DirEntry[]>;
    mkdir(path: string): Promise<void>;
    remove(path: string): Promise<void>;
    exists(path: string): Promise<boolean>;
    stat(path: string): Promise<FileStat>;
    private openRead;
    /**
     * Send a large file as an upload session: ordered chunks, each retried
     * independently with backoff, so one dropped connection costs one chunk rather
     * than the whole transfer. The file appears at `path` only on commit.
     */
    private uploadInChunks;
    /**
     * PUT one chunk, retrying transient failures. After any failure the session
     * is re-fetched: the server only counts fully-stored chunks, so its
     * `receivedBytes` tells us whether this chunk actually landed (return) or
     * must be resent (retry).
     */
    private putChunkWithRetry;
}
//# sourceMappingURL=fs.d.ts.map