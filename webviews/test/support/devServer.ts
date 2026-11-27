// Stops a `vp dev` server a browser test spawned.
//
// `vp dev` runs Vite in a child process, and SIGTERM to `vp` alone left that Vite running with
// nobody to stop it: each file that spawned one leaked about 1.1 GiB per run, and on
// react-apps-check the leaks piled up until every dev server file after a failing one timed out
// (2026-10-15, menu-focus). Detaching `vp` into a group of its own and signalling the group stops
// both on a normal exit, but the runner's `timeout` (scripts/ci/run-webviews-tests.sh) signals its
// own group, which a detached server has left; so the server stays in the test's group and this
// stops `vp`'s children by their parent pid, then `vp`.

import { spawnSync, type ChildProcess } from "node:child_process";

/** Stops `server`, a `vp dev` process, and the Vite it runs. */
export function stopDevServer(server: ChildProcess | null | undefined): void {
  if (!server?.pid || server.exitCode !== null || server.signalCode !== null) return;
  const pid = server.pid;
  // `pgrep -P` matches the parent pid exactly (Linux and macOS); no output when there are none.
  const children = (spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf8" }).stdout ?? "")
    .split(/\s+/)
    .filter(Boolean)
    .map(Number);
  for (const child of children) signal(child);
  signal(pid);
}

function signal(pid: number) {
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    // Already gone.
  }
}
