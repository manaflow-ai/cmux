// A Chromium launch's renderer processes and what they cost, from /proc (Linux only): the measures
// chat-100k-flat.bench.ts and coord-sim-load.bench.ts share.
import fs from "node:fs";

/// USER_HZ, the unit of /proc/PID/stat utime and stime on Linux.
export const TICK_HZ = 100;

/// The renderer processes under `root` (a Chromium launch), by their command line.
export function renderers(root: number): number[] {
  const children = new Map<number, number[]>();
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, "utf8");
      const parent = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      children.set(parent, [...(children.get(parent) ?? []), Number(entry)]);
    } catch {
      // Gone between the listing and the read.
    }
  }
  const out: number[] = [];
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      try {
        if (fs.readFileSync(`/proc/${child}/cmdline`, "utf8").includes("--type=renderer")) out.push(child);
      } catch {
        // Gone.
      }
      walk(child);
    }
  };
  walk(root);
  return out;
}

/// utime + stime of `pids` in clock ticks (a process gone since the listing counts nothing).
export function cpuTicks(pids: number[]): number {
  let ticks = 0;
  for (const pid of pids) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      ticks += Number(fields[11]) + Number(fields[12]);
    } catch {
      // Gone.
    }
  }
  return ticks;
}

/// A process's proportional set size, MB.
export const pssMB = (pid: number) =>
  Number(/^Pss:\s+(\d+) kB/m.exec(fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"))?.[1] ?? 0) / 1024;
