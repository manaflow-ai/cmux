import { closeSync, existsSync, fsyncSync, openSync, readFileSync, renameSync, writeSync } from "node:fs";
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

  /** Writes atomically and durably: temp file, fsync, rename, then fsync the directory. */
  save(state: HostStateData): void {
    const tmp = `${this.path}.${process.pid}.tmp`;
    const fd = openSync(tmp, "w");
    try {
      writeSync(fd, `${JSON.stringify(state)}\n`);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
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
