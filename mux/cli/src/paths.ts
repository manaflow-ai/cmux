import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Everything mux keeps on this Mac. `MUX_HOME` moves it (tests use a temp dir). */
export function muxHome(env: Record<string, string | undefined> = process.env): string {
  return env.MUX_HOME ?? join(homedir(), ".cmux", "mux");
}

export interface MuxPaths {
  home: string;
  memory: string;
  sessions: string;
  compactor: string;
  lock: string;
}

export function muxPaths(home = muxHome()): MuxPaths {
  const paths = {
    home,
    memory: join(home, "memory"),
    sessions: join(home, "state", "sessions"),
    compactor: join(home, "compactor"),
    lock: join(home, "state", "compact.lock"),
  };
  for (const dir of [paths.memory, paths.sessions, paths.compactor])
    mkdirSync(dir, { recursive: true });
  return paths;
}
