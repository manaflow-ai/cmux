import { dlopen, FFIType } from "bun:ffi";
import { closeSync, existsSync, fsyncSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";
import { dirname } from "node:path";
import { type HostStateData, loadState } from "../../packages/brain/src/core/state.ts";

export type { ChildRecord, HostStateData, OutboxEntry, OutstandingPrompt } from "../../packages/brain/src/core/state.ts";

/**
 * The brain host's durable state file ($MUX_HOME/state/host.json). The shape
 * and its rules live in the brain core (packages/brain/src/core/state.ts);
 * this is only the file. A missing or unreadable file loads as empty.
 */
export class HostStateFile {
  constructor(private readonly path: string) {}

  load(): HostStateData {
    let loaded: Partial<HostStateData> = {};
    if (existsSync(this.path)) {
      try {
        loaded = JSON.parse(readFileSync(this.path, "utf8")) as Partial<HostStateData>;
      } catch {
        loaded = {};
      }
    }
    return loadState(loaded);
  }

  /**
   * Writes atomically and durably: temp file, sync (F_FULLFSYNC on macOS, which
   * flushes the drive cache; fsync elsewhere), rename, then fsync the directory.
   * A failed write removes the temp file and throws; host.json is untouched.
   */
  save(state: HostStateData): void {
    const tmp = `${this.path}.${process.pid}.tmp`;
    const fd = openSync(tmp, "w");
    try {
      // writeSync may write less than asked: write the rest until all bytes are out.
      const bytes = Buffer.from(`${JSON.stringify(state)}\n`);
      for (let offset = 0; offset < bytes.length; ) {
        const written = writeSync(fd, bytes, offset, bytes.length - offset);
        if (written <= 0) throw new Error(`short write to ${tmp}`);
        offset += written;
      }
      if (!fullFsync(fd)) fsyncSync(fd);
    } catch (error) {
      closeSync(fd);
      rmSync(tmp, { force: true });
      throw error;
    }
    closeSync(fd);
    renameSync(tmp, this.path);
    try {
      const dir = openSync(dirname(this.path), "r");
      try {
        fsyncSync(dir);
      } finally {
        closeSync(dir);
      }
    } catch {
      // Not every file system syncs a directory; the rename is still atomic.
    }
  }
}

/** fcntl(F_FULLFSYNC) on macOS (the variadic third argument is not used, so none crosses FFI). */
const F_FULLFSYNC = 51;
const libc = (() => {
  if (process.platform !== "darwin") return undefined;
  try {
    return dlopen("/usr/lib/libSystem.B.dylib", { fcntl: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 } });
  } catch {
    return undefined;
  }
})();

/** True when F_FULLFSYNC flushed `fd`; false where it does not exist or failed (then fsync). */
function fullFsync(fd: number): boolean {
  return libc !== undefined && libc.symbols.fcntl(fd, F_FULLFSYNC) === 0;
}
