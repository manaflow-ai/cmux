import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Everything the mux keeps on this Mac. Tagged builds and tests pass their own MUX_HOME. */
export function muxHome(env: Record<string, string | undefined> = process.env): string {
  return env.MUX_HOME ?? join(homedir(), ".cmux", "mux");
}

export interface MuxPaths {
  home: string;
  /** OptMem git repo (LOG.txt + TREE/). */
  memory: string;
  /** The mux's acpmux session cwd: CLAUDE.md and .claude/settings.json. */
  session: string;
  /** Per-Claude-session "seen" cursors for the memory hooks. */
  hookSessions: string;
  compactor: string;
  /** Launchers on the mux's PATH (`mux`). */
  bin: string;
  hostLock: string;
  hostState: string;
  compactLock: string;
}

export function muxPaths(home = muxHome()): MuxPaths {
  const paths: MuxPaths = {
    home,
    memory: join(home, "memory"),
    session: join(home, "session"),
    hookSessions: join(home, "state", "sessions"),
    compactor: join(home, "compactor"),
    bin: join(home, "bin"),
    hostLock: join(home, "state", "host.lock"),
    hostState: join(home, "state", "host.json"),
    compactLock: join(home, "state", "compact.lock"),
  };
  for (const dir of [paths.memory, paths.session, paths.hookSessions, paths.compactor, paths.bin])
    mkdirSync(dir, { recursive: true });
  return paths;
}
