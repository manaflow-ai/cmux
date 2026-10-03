import { dlopen, FFIType } from "bun:ffi";
import { closeSync, ftruncateSync, openSync, readFileSync, writeSync } from "node:fs";

/**
 * One holder at a time, enforced by the kernel: the holder keeps the lock file
 * open with an exclusive flock(2) for its whole life. The kernel drops the lock
 * when the holder's process ends, however it ends, so there is no stale lock,
 * no takeover and no pid reuse to judge. The file stays in place (removing a
 * locked file would let a second taker lock a new file at the same path); its
 * text "<pid>\n<start ms>\n" is for diagnostics only.
 *
 * A second takeLock in the same process is refused too (flock locks belong to
 * the open file, not the process): a second host in this process is still a
 * second host. The Rust shell takes the same lock with std File::try_lock,
 * which is flock on Unix.
 *
 * Returns a release function, or undefined when another open file holds it.
 */
export function takeLock(path: string): (() => void) | undefined {
  const fd = openSync(path, "a+", 0o644);
  if (flock(fd, LOCK_EX | LOCK_NB) !== 0) {
    closeSync(fd);
    return undefined;
  }
  try {
    ftruncateSync(fd, 0);
    writeSync(fd, `${process.pid}\n${Math.round(performance.timeOrigin)}\n`);
  } catch {
    // Diagnostics only: the flock is the lock.
  }
  let held = true;
  return () => {
    if (!held) return;
    held = false;
    closeSync(fd); // Closing the last descriptor drops the flock.
  };
}

/** The pid written by the current holder, or undefined when nobody holds the lock. */
export function lockHolder(path: string): number | undefined {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return undefined;
  }
  try {
    if (flock(fd, LOCK_SH | LOCK_NB) === 0) return undefined; // Free: nobody holds it.
    const pid = Number(readFileSync(path, "utf8").split("\n")[0]);
    return Number.isInteger(pid) && pid > 0 ? pid : undefined;
  } finally {
    closeSync(fd);
  }
}

const LOCK_SH = 1;
const LOCK_EX = 2;
const LOCK_NB = 4;

const libc = dlopen(process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
  flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});

function flock(fd: number, operation: number): number {
  return libc.symbols.flock(fd, operation);
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}
