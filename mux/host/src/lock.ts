import { closeSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";

/**
 * One holder at a time: a lock file holding the owner's pid, stale when that
 * pid is gone. Returns a release function, or undefined when a live process
 * holds it.
 */
export function takeLock(path: string): (() => void) | undefined {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = openSync(path, "wx");
      writeSync(fd, String(process.pid));
      closeSync(fd);
      return () => {
        try {
          if (Number(readFileSync(path, "utf8").trim()) === process.pid) rmSync(path, { force: true });
        } catch {
          // Already gone.
        }
      };
    } catch {
      let owner = 0;
      try {
        owner = Number(readFileSync(path, "utf8").trim());
      } catch {
        continue; // Released between our open and read: try again.
      }
      if (owner && owner !== process.pid && isAlive(owner)) return undefined;
      rmSync(path, { force: true });
    }
  }
  return undefined;
}

export function lockHolder(path: string): number | undefined {
  try {
    const pid = Number(readFileSync(path, "utf8").trim());
    return pid && isAlive(pid) ? pid : undefined;
  } catch {
    return undefined;
  }
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}
