import { spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync } from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";
import type { Readable } from "node:stream";

// Starting the acpmux daemon when its socket is not reachable (the app's
// launch contract: ACPMUX_BIN, ACPMUX_HOME, ACPMUX_SOCKET). The daemon runs
// detached in its own process group with its log in $ACPMUX_HOME/daemon.log.
// Readiness is the daemon's own signal: one line on the pipe it gets with
// --ready-fd 3, written once its socket listens; no watch and no sleep loop.

/** Whether something accepts connections on the Unix socket. */
export function socketReachable(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    if (!existsSync(path)) return resolve(false);
    const socket = connect(path);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
}

/**
 * Resolves on the first line the daemon writes to its ready pipe. Rejects when
 * the pipe closes or the daemon exits first, or after `timeoutMs`.
 */
export function waitForReady(pipe: Readable, options: { timeoutMs: number; exited?: Promise<string> }): Promise<void> {
  return new Promise((resolve, reject) => {
    let done = false;
    let text = "";
    const finish = (error?: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      pipe.off("data", onData);
      pipe.off("close", onClose);
      if (error) reject(error);
      else resolve();
    };
    const onData = (chunk: Buffer | string) => {
      text += chunk.toString();
      if (text.includes("\n")) finish();
    };
    const onClose = () => finish(new Error("acpmux daemon closed its ready pipe before it was ready"));
    pipe.on("data", onData);
    pipe.on("close", onClose);
    const timer = setTimeout(() => finish(new Error(`acpmux daemon not ready after ${options.timeoutMs} ms`)), options.timeoutMs);
    options.exited?.then((why) => finish(new Error(`acpmux daemon exited before it was ready: ${why}`)));
  });
}

/**
 * Starts `$ACPMUX_BIN daemon run` unless the socket answers. Returns the
 * started pid, or undefined when a daemon was already running.
 */
export async function ensureAcpmuxDaemon(env: Record<string, string | undefined>, socket: string, log: (line: string) => void): Promise<number | undefined> {
  if (await socketReachable(socket)) return undefined;
  const bin = env.ACPMUX_BIN;
  if (!bin) throw new Error(`acpmux is not reachable at ${socket} and ACPMUX_BIN is not set`);
  const home = env.ACPMUX_HOME ?? dirname(socket);
  mkdirSync(home, { recursive: true });
  const out = openSync(join(home, "daemon.log"), "a");
  // The daemon writes one line to fd 3 once its socket listens (acpmux --ready-fd): a
  // readiness signal with no directory watch and no polling.
  const child = spawn(bin, ["daemon", "run", "--ready-fd", "3"], {
    detached: true,
    stdio: ["ignore", out, out, "pipe"],
    env: { ...process.env, ...env, ACPMUX_HOME: home, ACPMUX_SOCKET: socket } as Record<string, string>,
  });
  const exited = new Promise<string>((resolve) => {
    child.once("exit", (code, signal) => resolve(`code ${code ?? "?"} signal ${signal ?? "-"}`));
    child.once("error", (error) => resolve(String(error)));
  });
  log(`started acpmux daemon ${bin} (pid ${child.pid}, ACPMUX_HOME ${home})`);
  try {
    await waitForReady(child.stdio[3] as Readable, { timeoutMs: 30_000, exited });
  } finally {
    (child.stdio[3] as Readable | null)?.destroy();
    child.unref();
  }
  return child.pid;
}
