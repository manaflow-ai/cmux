import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
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

  /** Writes atomically (temp file, then rename). */
  save(state: HostStateData): void {
    const tmp = `${this.path}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(state)}\n`);
    renameSync(tmp, this.path);
  }
}
