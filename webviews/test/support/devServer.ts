// Stops a `vp dev` server a browser test spawned.

import type { ChildProcess } from "node:child_process";

/** Stops `server`, a `vp dev` process. */
export function stopDevServer(server: ChildProcess | null | undefined): void {
  server?.kill();
}
