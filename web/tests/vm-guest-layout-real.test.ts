import { expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { GUEST_CMUX_SHIM } from "../services/vms/guestCli";

// Run with the shipped daemon, without rebuilding Rust:
// CMUX_TUI_TEST_BIN=/path/to/cmux-tui bun test tests/vm-guest-layout-real.test.ts
// This integration test compares the daemon's resulting graph, not CLI argv.
const binary = process.env.CMUX_TUI_TEST_BIN;
(binary ? test : test.skip)("guest layouts retain asymmetric and nested split geometry on the real daemon", async () => {
  const root = mkdtempSync(join(tmpdir(), "cmux-layout-real-"));
  const home = join(root, "home");
  mkdirSync(home);
  const shim = join(root, "cmux");
  writeFileSync(shim, GUEST_CMUX_SHIM);
  const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, XDG_CONFIG_HOME: join(home, ".config"),
    CMUX_TUI_BIN: binary!, CMUX_TUI_SESSION: `layout-real-${process.pid}`, SHELL: "/bin/bash", TERM: "xterm-256color" };
  const daemonArgs = [binary!, "--session", env.CMUX_TUI_SESSION];
  const run = (args: string[], guest = false) => {
    const result = spawnSync(guest ? "/bin/sh" : binary!, guest ? [shim, ...args] : [...daemonArgs.slice(1), "--json", ...args],
      { env, encoding: "utf8", timeout: 20_000 });
    if (result.status !== 0) throw new Error(`${args.join(" ")}: ${result.stderr}`);
    const parsed = JSON.parse(result.stdout);
    return parsed.value ?? parsed;
  };
  const daemon = spawn(binary!, [...daemonArgs.slice(1), "server", "start"], { env, stdio: "ignore" });
  const exited = new Promise<void>((resolve, reject) => { daemon.once("exit", () => resolve()); daemon.once("error", reject); });
  try {
    const deadline = Date.now() + 10_000;
    while (spawnSync(binary!, [...daemonArgs.slice(1), "server", "status"], { env, stdio: "ignore", timeout: 1000 }).status !== 0) {
      if (Date.now() >= deadline) throw new Error("daemon did not become ready");
      await delay(25);
    }
    const leaf = (name: string) => ({ pane: { surfaces: [{ type: "terminal", name }] } });
    const layouts = [
      { direction: "horizontal", split: 0.35, children: [leaf("left"), leaf("right")] },
      { direction: "vertical", split: 0.7, children: [leaf("top"), leaf("bottom")] },
      { direction: "horizontal", split: 0.2, children: [leaf("left"),
        { direction: "vertical", split: 0.65, children: [leaf("upper-right"), leaf("lower-right")] }] },
    ];
    for (const [index, layout] of layouts.entries()) {
      const document = join(root, `layout-${index}.json`);
      writeFileSync(document, JSON.stringify({ layout }));
      const applied = run(["layout", "apply", "--name", `layout-${index}`, "--json", document], true);
      const exported = run(["layout", "export", "--workspace", applied.workspace_id, "--json"], true);
      expect(exported.layout.direction).toBe(layout.direction);
      expect(exported.layout.split).toBeCloseTo(layout.split, 4);
      if (index === 2) {
        expect(exported.layout.children[1].direction).toBe("vertical");
        expect(exported.layout.children[1].split).toBeCloseTo(0.65, 4);
      }
    }
  } finally {
    spawnSync(binary!, [...daemonArgs.slice(1), "server", "stop"], { env, stdio: "ignore", timeout: 5000 });
    daemon.kill();
    await exited;
    rmSync(root, { recursive: true, force: true });
  }
}, 60_000);
