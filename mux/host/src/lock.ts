import { dlopen, FFIType } from "bun:ffi";
import { spawnSync } from "node:child_process";
import { closeSync, fstatSync, ftruncateSync, openSync, readFileSync, writeSync } from "node:fs";

/**
 * One holder at a time, enforced by the kernel: the holder keeps the lock file
 * open with an exclusive flock(2) for its whole life. The kernel drops the lock
 * when the holder's process ends, however it ends, so there is no stale lock,
 * no takeover and no pid reuse to judge. The file stays in place (removing a
 * locked file would let a second taker lock a new file at the same path); its
 * text "<pid>\n<start ms>\nflock\n" is for diagnostics only.
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
  // The descriptor must not leak into children (the acpmux daemon outlives the
  // host): a child holding it would keep the flock after this host ends.
  setCloseOnExec(fd);
  if (flock(fd, LOCK_EX | LOCK_NB) !== 0) {
    closeSync(fd);
    return undefined;
  }
  let older: number | undefined;
  try {
    older = olderHost(path, fd);
  } catch (error) {
    // The check could not decide: refuse, and drop the flock with the descriptor.
    console.error(`mux lock: checking ${path} for an older host failed: ${String(error)}; not starting`);
    closeSync(fd);
    return undefined;
  }
  if (older !== undefined) {
    console.error(`mux lock: an older mux host (pid ${older}) holds ${path} without a kernel lock; not starting`);
    closeSync(fd);
    return undefined;
  }
  try {
    ftruncateSync(fd, 0);
    writeSync(fd, `${process.pid}\n${Math.round(performance.timeOrigin)}\n${FLOCK_MARK}\n`);
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

/** Marks a lock file written by a kernel-lock host. */
const FLOCK_MARK = "flock";

/**
 * Upgrade check, REMOVE AFTER ONE RELEASE (plans/cmux-next/chief-mac.md section 2).
 * Older hosts held this lock by file text only ("<pid>" or "<pid>\n<start ms>",
 * no flock). We hold the flock now; if the text is in an old format and names a
 * live process that started no later than the text says (one-sided: a reused
 * pid starts later), that older host is still running: returns its pid.
 * Pid-only text uses the file's mtime as the recorded start.
 */
function olderHost(path: string, fd: number): number | undefined {
  let lines: string[];
  try {
    lines = readFileSync(path, "utf8").trim().split("\n");
  } catch {
    return undefined;
  }
  if (lines.includes(FLOCK_MARK)) return undefined;
  const pid = Number(lines[0]);
  if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid || !isAlive(pid)) return undefined;
  const recorded = lines[1] ? Number(lines[1]) : fstatSync(fd).mtimeMs;
  if (!Number.isFinite(recorded)) return undefined;
  const started = processStartMs(pid);
  // ps truncates to whole seconds; unknown start: assume the older host is live.
  if (started === undefined || started <= recorded + START_SLACK_MS) return pid;
  return undefined;
}

const START_SLACK_MS = 1_000;

/** The process's OS start time, epoch ms, from `ps -o lstart` in the C locale and UTC. */
function processStartMs(pid: number): number | undefined {
  // Absolute path: the PATH of a host started by the app is not trusted for this.
  const result = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], {
    env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
    encoding: "utf8",
  });
  const text = result.status === 0 ? result.stdout.trim().replace(/\s+/g, " ") : "";
  const ms = text ? Date.parse(`${text} UTC`) : Number.NaN;
  return Number.isFinite(ms) ? ms : undefined;
}

const LOCK_SH = 1;
const LOCK_EX = 2;
const LOCK_NB = 4;

const libc = dlopen(process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
  flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
  // Both are variadic in C. Each call here passes only the fixed arguments
  // (FIOCLEX and F_GETFD take no third one), so no variadic value is passed
  // through FFI (Apple arm64 passes variadic values on the stack).
  ioctl: { args: [FFIType.i32, FFIType.u64], returns: FFIType.i32 },
  fcntl: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});

/** ioctl(FIOCLEX): set close-on-exec (_IO('f', 1) on macOS, 0x5451 on Linux). */
const FIOCLEX = process.platform === "darwin" ? 0x20006601n : 0x5451n;
const F_GETFD = 1;
const FD_CLOEXEC = 1;

/** Sets close-on-exec on `fd`; throws when it does not stick. */
function setCloseOnExec(fd: number): void {
  libc.symbols.ioctl(fd, FIOCLEX);
  const flags = libc.symbols.fcntl(fd, F_GETFD);
  if (flags < 0 || (flags & FD_CLOEXEC) === 0) {
    closeSync(fd);
    throw new Error(`mux lock: cannot set close-on-exec on ${fd}`);
  }
}

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
