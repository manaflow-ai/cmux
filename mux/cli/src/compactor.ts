import { closeSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";
import { compact, SUMMARY_INSTRUCTIONS, wake, type Summarize } from "@mux/brain";
import type { FileMemoryStore } from "./file-store.ts";

/** One compactor at a time: a lock file holding the owner's pid (stale when that pid is gone). */
export function takeLock(path: string): (() => void) | undefined {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = openSync(path, "wx");
      writeSync(fd, String(process.pid));
      closeSync(fd);
      return () => rmSync(path, { force: true });
    } catch {
      const owner = Number(readFileSync(path, "utf8").trim());
      if (owner && isAlive(owner)) return undefined;
      rmSync(path, { force: true });
    }
  }
  return undefined;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Builds the summaries the wake view needs, in bounded steps, until none are
 * missing or a step makes no progress. `summarize` is the cheap model.
 */
export async function compactUntilDone(
  store: FileMemoryStore,
  budget: number,
  summarize: Summarize,
): Promise<number> {
  let total = 0;
  for (;;) {
    const { missing } = await wake(store, budget);
    if (missing.length === 0) return total;
    const written = await compact(store, missing, summarize, 8);
    store.commit(`compact ${written}`);
    total += written;
    if (written === 0) return total;
  }
}

async function acpmux(args: string[], stdin?: string): Promise<string> {
  const child = Bun.spawn(["acpmux", ...args], {
    stdin: stdin === undefined ? "ignore" : new Blob([stdin]),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (code !== 0)
    throw new Error(`acpmux ${args[0]} failed (${code}): ${(err || out).trim().slice(0, 300)}`);
  return out;
}

/**
 * A summarizer on a cheap acpmux agent (default `claude/haiku`, no tools). One
 * session per compactor run, removed when the run ends, so its context never
 * grows across runs.
 */
export async function acpmuxSummarizer(
  cwd: string,
  harness: string,
): Promise<{ summarize: Summarize; close: () => Promise<void> }> {
  const session = `mux-compactor-${process.pid}`;
  await acpmux(["ensure", session, "-m", harness, "--cwd", cwd, "--policy", "deny-all", "--json"]);
  return {
    summarize: async ({ left, right }) =>
      (
        await acpmux(
          ["send", session, "-q", "--stall", "0", "--on-permission", "deny", "-"],
          `${SUMMARY_INSTRUCTIONS}\nReply with the merged line only.\n\nA: ${left}\nB: ${right}`,
        )
      ).trim(),
    close: async () => {
      await acpmux(["kill", session, "--purge"]).catch(() => "");
    },
  };
}
