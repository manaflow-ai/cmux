// A browser test's `vp dev` server stops whole (test/support/devServer.ts). `vp dev` runs Vite as a
// child process, and SIGTERM to `vp` alone left that child running with nobody to stop it: every
// file that spawned one leaked a Vite of about 1.1 GiB per run, and on react-apps-check the leaks
// piled up until the dev server files after a failing one timed out (2026-10-15, menu-focus).
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("dev-server-stop.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  let server: ChildProcess | null = null;
  let started: number[] = [];

  const alive = (pid: number) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };

  afterAll(() => {
    // Whatever the test left running, by the pids it saw.
    for (const pid of started) if (alive(pid)) process.kill(pid, "SIGKILL");
  });

  test("stopping a vp dev server stops the Vite it started", async () => {
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
    });
    await new Promise<void>((resolve, reject) => {
      const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    const children = spawnSync("pgrep", ["-P", String(server.pid)], { encoding: "utf8" })
      .stdout.split(/\s+/)
      .filter(Boolean)
      .map(Number);
    started = [server.pid!, ...children];
    // vp runs Vite in a child process.
    expect(children.length).toBeGreaterThan(0);

    stopDevServer(server);
    const deadline = Date.now() + 10_000;
    // fixed-wait: nothing reports a grandchild's exit (Vite runs in vp's child), so this polls the process table.
    while (started.some(alive) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 100));
    expect(started.filter(alive)).toEqual([]);
  });
});
