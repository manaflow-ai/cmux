import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { acpmuxSocketPath } from "../src/acpmux-client.ts";
import { PassThrough } from "node:stream";
import { acpmuxDaemonHome, readyRefusal, waitForReady } from "../src/acpmux-daemon.ts";

// The acpmux socket every host and client resolves, against the shared cases
// (cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json) the Rust
// policy, the Swift host, cmux-tui and the Chief run too: a configured
// ACPMUX_SOCKET past the Unix socket limit and a long home reach the short alias
// the daemon binds.
const cases = JSON.parse(
  readFileSync(
    join(import.meta.dir, "../../../cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json"),
    "utf8",
  ),
) as { sockets: [string, number, string][]; configured_sockets: [string, string, number, string][] };

test("a home's default socket matches the shared cases", () => {
  expect(cases.sockets.length).toBeGreaterThan(0);
  for (const [home, uid, want] of cases.sockets)
    expect(acpmuxSocketPath({ ACPMUX_HOME: home }, uid)).toBe(want);
});

test("a configured ACPMUX_SOCKET matches the shared cases", () => {
  expect(cases.configured_sockets.length).toBeGreaterThan(0);
  for (const [configured, home, uid, want] of cases.configured_sockets)
    expect(acpmuxSocketPath({ ACPMUX_SOCKET: configured, ACPMUX_HOME: home }, uid)).toBe(want);
});

test("a started daemon's home is never the short alias folder", () => {
  const user = "/Users/a-user-whose-home-folder-name-is-long-enough-to-push-the-default-socket-path";
  const socket = acpmuxSocketPath({ HOME: user }, 501);
  expect(socket.startsWith("/tmp/acpmux-501/")).toBe(true);
  expect(acpmuxDaemonHome({ HOME: user }, socket, 501)).toBe(join(user, ".acpmux"));
  const configured = `/${"e".repeat(98)}/s.sock`;
  const alias = acpmuxSocketPath({ ACPMUX_SOCKET: configured }, 501);
  expect(alias.startsWith("/tmp/acpmux-501/")).toBe(true);
  expect(acpmuxDaemonHome({ ACPMUX_SOCKET: configured, HOME: user }, alias, 501)).toBe(dirname(configured));
  expect(acpmuxDaemonHome({ HOME: user }, "/tmp/run/acpmux.sock", 501)).toBe("/tmp/run");
});

test("a daemon that refused to start fails the wait with its own reason", async () => {
  const refused = "acpmux: this daemon's executable /tmp/a/acpmux is in a temporary folder";
  expect(readyRefusal(JSON.stringify({ ready: false, refused }))).toBe(refused);
  expect(readyRefusal('{"ready":true,"pid":1}')).toBeUndefined();
  expect(readyRefusal('{"ready":false,"lockHeld":true}')).toBeUndefined();
  const pipe = new PassThrough();
  const wait = waitForReady(pipe, { timeoutMs: 5_000 });
  pipe.write(JSON.stringify({ ready: false, refused }) + "\n");
  await expect(wait).rejects.toThrow(refused);
  const ok = new PassThrough();
  const ready = waitForReady(ok, { timeoutMs: 5_000 });
  ok.write('{"ready":true,"pid":1}\n');
  await expect(ready).resolves.toBeUndefined();
});
