// The parity runner's own browser host for the host-* backends. Without it,
// the first `cmux-browser-host eval` started a detached `serve` (its own
// process group) that outlived the run: one leaked host, with its browser
// and kept tabs, per run. The runner starts `serve` on a private socket
// (a new 0700 directory), so every `eval` of the run connects to it, and
// stops it by its exact PID at the end, also when the run fails or the
// runner gets SIGINT or SIGTERM. The host's browser exits with it (its
// CDP pipe closes).
import net from "node:net";
import path from "node:path";
import { spawn } from "node:child_process";
import { makeTestDir, removeTestDir } from "./test-dirs.mjs";

const START_MS = 10_000;
const STOP_MS = 5_000;

const connects = (socket) =>
  new Promise((resolve) => {
    const c = net.connect(socket);
    c.once("connect", () => {
      c.destroy();
      resolve(true);
    });
    c.once("error", () => resolve(false));
  });

// Started hosts, for the exit and signal handlers.
const running = new Set();
let handlersInstalled = false;
function installHandlers() {
  if (handlersInstalled) return;
  handlersInstalled = true;
  // Last resort when the event loop cannot run `stop` any more.
  process.on("exit", () => {
    for (const child of running) child.kill("SIGKILL");
  });
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => {
      for (const child of running) child.kill("SIGKILL");
      process.exit(128 + (signal === "SIGINT" ? 2 : 15));
    });
  }
}

/// Starts `cmd ...args serve --socket <private socket>`; resolves once it
/// accepts connections. `stop()` ends that exact process and removes the
/// directory.
export async function startOwnHost({ cmd, args = [], env = process.env }) {
  const dir = makeTestDir("parity-host-", { mode: 0o700 });
  const socket = path.join(dir, "host.sock");
  const child = spawn(cmd, [...args, "serve", "--socket", socket], { stdio: "ignore", env });
  running.add(child);
  installHandlers();
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      const timer = setTimeout(() => child.kill("SIGKILL"), STOP_MS);
      await exited;
      clearTimeout(timer);
    }
    running.delete(child);
    removeTestDir(dir);
  };
  const deadline = Date.now() + START_MS;
  while (!(await connects(socket))) {
    if (child.exitCode !== null || Date.now() > deadline) {
      await stop();
      throw new Error(`the parity host did not start on ${socket}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return { pid: child.pid, socket, stop };
}

/// Runs `fn(host)` with a host of its own, stopped afterwards in every case.
export async function withOwnHost(spec, fn) {
  const host = await startOwnHost(spec);
  try {
    return await fn(host);
  } finally {
    await host.stop();
  }
}
