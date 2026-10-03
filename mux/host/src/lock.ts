import { spawnSync } from "node:child_process";
import { linkSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";

/**
 * One holder at a time: a lock file holding the owner's pid, stale when that
 * pid is gone. Returns a release function, or undefined when a live process
 * holds it (or another taker is taking a stale lock over right now).
 *
 * The lock file is never empty: the pid is written to a private file first and
 * then hard-linked into place, which fails if the lock exists. Only a taker
 * that holds the takeover lock (`<path>.takeover`, taken the same way) may
 * remove a stale lock, and it reads the lock again under the takeover lock
 * first, so it never removes a lock that another taker has just taken.
 *
 * The lock holds "<pid>\n<start time>\n". A live pid whose start time differs
 * is a reused pid, so the lock is stale. A lock with a pid only (older hosts)
 * is checked by pid.
 */
export function takeLock(path: string): (() => void) | undefined {
  for (let attempt = 0; attempt < 3; attempt++) {
    if (linkPid(path)) return release(path);
    const owner = readOwner(path);
    if (owner === "gone") continue; // Released between our link and read: try again.
    if (owner === "held") return undefined;
    // Stale: only the takeover lock's holder may remove it.
    const takeover = `${path}.takeover`;
    if (!linkPid(takeover)) {
      // Another taker is taking it over. A takeover lock outlives its taker
      // only if that taker died inside these few calls; then it is old.
      if (!isOld(takeover)) return undefined;
      rmSync(takeover, { force: true });
      if (!linkPid(takeover)) return undefined;
    }
    try {
      const again = readOwner(path);
      if (again === "held") return undefined; // Another taker won the takeover first.
      if (again === "stale") rmSync(path, { force: true });
      if (linkPid(path)) return release(path);
    } finally {
      rmSync(takeover, { force: true });
    }
  }
  return undefined;
}

/** A lock file with no valid pid this old is left over from a crashed writer (older hosts wrote the pid after creating the file). */
const ORPHAN_MS = 10_000;

/** Writes this process's pid to a private file and links it to `path`; false if `path` exists. */
function linkPid(path: string): boolean {
  const tmp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
  writeFileSync(tmp, `${process.pid}\n${ownStart()}\n`);
  try {
    linkSync(tmp, path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return false;
    throw error;
  } finally {
    rmSync(tmp, { force: true });
  }
}

function release(path: string): () => void {
  return () => {
    try {
      if (parse(readFileSync(path, "utf8"))?.pid === process.pid) rmSync(path, { force: true });
    } catch {
      // Already gone.
    }
  };
}

/** "held": a live pid (our own counts: a second host in this process is still a second host). */
function readOwner(path: string): "held" | "stale" | "gone" {
  let text: string;
  try {
    text = readFileSync(path, "utf8").trim();
  } catch {
    return "gone";
  }
  const owner = parse(text);
  if (!owner) return isOld(path) ? "stale" : "held";
  return isOwnerAlive(owner) ? "held" : "stale";
}

interface Owner {
  pid: number;
  /** `ps -o lstart` of the owner; undefined in locks written by older hosts. */
  start?: string;
}

function parse(text: string): Owner | undefined {
  const [first = "", second = ""] = text.trim().split("\n");
  const pid = Number(first.trim());
  if (!Number.isInteger(pid) || pid <= 0) return undefined;
  const start = second.trim();
  return start ? { pid, start } : { pid };
}

function isOwnerAlive(owner: Owner): boolean {
  if (!isAlive(owner.pid)) return false;
  if (owner.start === undefined) return true;
  const start = processStart(owner.pid);
  // Unknown start (ps failed): keep the old pid-only answer rather than steal a live lock.
  return start === undefined || start === owner.start;
}

let cachedOwnStart: string | undefined;
function ownStart(): string {
  cachedOwnStart ??= processStart(process.pid) ?? "";
  return cachedOwnStart;
}

/** The process's start time as `ps -o lstart` prints it in the C locale and UTC. */
function processStart(pid: number): string | undefined {
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], {
    env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
    encoding: "utf8",
  });
  const start = result.status === 0 ? result.stdout.trim() : "";
  return start || undefined;
}

function isOld(path: string): boolean {
  try {
    return Date.now() - statSync(path).mtimeMs > ORPHAN_MS;
  } catch {
    return true;
  }
}

export function lockHolder(path: string): number | undefined {
  try {
    const owner = parse(readFileSync(path, "utf8"));
    return owner && isOwnerAlive(owner) ? owner.pid : undefined;
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
