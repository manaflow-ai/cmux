// First-run finding 6: an install the network dropped stayed failed after the network came back.
// The install command waits for the network and runs again by itself, inside the one command the
// person's click started (the host runs a command only on a click, so the page cannot start a
// second one on its own). These run the real wrapper in bash with a stand-in installer and a
// stand-in network check.
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { OFFLINE_MARK, RETRY_MARK, withNetworkRetry } from "../src/agent-session/acpmux/harnesses/installRetry";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/// A folder with counters: `runs` (installer runs) and `checks` (network checks).
function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), "cmux-install-retry-"));
  dirs.push(dir);
  writeFileSync(join(dir, "runs"), "0");
  writeFileSync(join(dir, "checks"), "0");
  return dir;
}

const bump = (dir: string, name: string) => `n=$(($(cat ${dir}/${name}) + 1)); echo $n > ${dir}/${name}`;
const count = (dir: string, name: string) => Number(readFileSync(join(dir, name), "utf8").trim());

function run(command: string) {
  const ran = Bun.spawnSync(["/bin/bash", "-c", command], { stdout: "pipe", stderr: "pipe" });
  return { code: ran.exitCode, output: ran.stdout.toString() + ran.stderr.toString() };
}

test("a download the network dropped waits for the network, then installs again by itself", () => {
  const dir = scratch();
  // The first run loses the network mid-download; the network is back on the third check.
  const installer = `${bump(dir, "runs")}; echo Downloading; if [ $n -eq 1 ]; then echo "curl: (56) Recv failure: Connection reset by peer"; exit 56; fi; echo installed`;
  const online = `${bump(dir, "checks")}; [ $n -ge 3 ]`;
  const { code, output } = run(withNetworkRetry(installer, { online, pollSeconds: 0.01 }));
  expect(code).toBe(0);
  expect(count(dir, "runs")).toBe(2);
  const lines = output.split("\n").filter(Boolean);
  expect(lines).toContain(OFFLINE_MARK);
  expect(lines).toContain(RETRY_MARK);
  expect(lines.at(-1)).toBe("installed");
});

test("a failure while the network is down retries once it is back, whatever the installer said", () => {
  const dir = scratch();
  // Claude Code's own words when its install fails, with the network down at that moment.
  const installer = `${bump(dir, "runs")}; if [ $n -eq 1 ]; then echo "Failed: Try running with --force to override checks"; exit 1; fi; echo installed`;
  const online = `${bump(dir, "checks")}; [ $n -ge 2 ]`;
  const { code } = run(withNetworkRetry(installer, { online, pollSeconds: 0.01 }));
  expect(code).toBe(0);
  expect(count(dir, "runs")).toBe(2);
});

test("a failure with the network up is the installer's own: it runs once and keeps its exit code", () => {
  const dir = scratch();
  const installer = `${bump(dir, "runs")}; echo "npm error code EACCES"; exit 243`;
  const { code, output } = run(withNetworkRetry(installer, { online: "true", pollSeconds: 0.01 }));
  expect(code).toBe(243);
  expect(count(dir, "runs")).toBe(1);
  expect(output).not.toContain(RETRY_MARK);
  expect(output.trim().split("\n").at(-1)).toBe("npm error code EACCES");
});

test("a network that never comes back ends the wait with the offline line, and the failure", () => {
  const dir = scratch();
  const installer = `${bump(dir, "runs")}; echo "curl: (6) Could not resolve host: claude.ai"; exit 6`;
  const { code, output } = run(withNetworkRetry(installer, { online: "false", pollSeconds: 0.01, waitSeconds: 0.05 }));
  expect(code).toBe(6);
  expect(count(dir, "runs")).toBe(1);
  expect(output.trim().split("\n").at(-1)).toBe(OFFLINE_MARK);
});

test("a network that keeps dropping stops after three runs", () => {
  const dir = scratch();
  const installer = `${bump(dir, "runs")}; echo "curl: (7) Failed to connect"; exit 7`;
  const online = `${bump(dir, "checks")}; [ $((n % 2)) -eq 0 ]`;
  const { code } = run(withNetworkRetry(installer, { online, pollSeconds: 0.01 }));
  expect(code).toBe(7);
  expect(count(dir, "runs")).toBe(3);
});
