import { spawn } from "node:child_process";
import { existsSync, mkdirSync, openSync, watch } from "node:fs";
import { connect } from "node:net";
import { dirname, join } from "node:path";

// Starting the acpmux daemon when its socket is not reachable (the app's
// launch contract: ACPMUX_BIN, ACPMUX_HOME, ACPMUX_SOCKET). The daemon runs
// detached in its own process group with its log in $ACPMUX_HOME/daemon.log.
// Readiness is a file-system event on the socket's directory followed by a
// successful connect; no sleep loop.

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
 * Resolves once `path` accepts connections: checks now, then on every change
 * in its directory. Rejects when `exited` settles first or after `timeoutMs`.
 */
export function waitForSocket(path: string, options: { timeoutMs: number; exited?: Promise<string> }): Promise<void> {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true });
  return new Promise((resolve, reject) => {
    let done = false;
    const finish = (error?: Error) => {
      if (done) return;
      done = true;
      watcher.close();
      clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    };
    let checking = false;
    let again = false;
    const check = async () => {
      if (checking) {
        again = true;
        return;
      }
      checking = true;
      do {
        again = false;
        if (await socketReachable(path)) return finish();
      } while (again && !done);
      checking = false;
    };
    const watcher = watch(dir, () => void check());
    const timer = setTimeout(() => finish(new Error(`acpmux socket ${path} not ready after ${options.timeoutMs} ms`)), options.timeoutMs);
    options.exited?.then((why) => finish(new Error(`acpmux daemon exited before its socket was ready: ${why}`)));
    void check();
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
  const child = spawn(bin, ["daemon", "run"], {
    detached: true,
    stdio: ["ignore", out, out],
    env: { ...process.env, ...env, ACPMUX_HOME: home, ACPMUX_SOCKET: socket } as Record<string, string>,
  });
  const exited = new Promise<string>((resolve) => {
    child.once("exit", (code, signal) => resolve(`code ${code ?? "?"} signal ${signal ?? "-"}`));
    child.once("error", (error) => resolve(String(error)));
  });
  child.unref();
  log(`started acpmux daemon ${bin} (pid ${child.pid}, ACPMUX_HOME ${home})`);
  await waitForSocket(socket, { timeoutMs: 30_000, exited });
  return child.pid;
}
