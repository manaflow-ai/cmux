// `cmux browser repl` subcommands that print for a person or read a
// terminal, against the built CLI and a fake control socket that answers
// the REPL's socket methods the way the app does; no app is needed.
//
//   PARITY_CMUX_CLI=<built cmux CLI> node --test tests/browser-parity/unit/repl-cli.test.mjs
// Skipped without PARITY_CMUX_CLI.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

const CLI = process.env.PARITY_CMUX_CLI;
const skip = !CLI && "set PARITY_CMUX_CLI";
const WORKSPACE = "11111111-2222-3333-4444-555555555555";

function fakeSocket(file, calls, sessions) {
  const server = net.createServer((conn) => {
    readline.createInterface({ input: conn, crlfDelay: Infinity }).on("line", (line) => {
      let req;
      try {
        req = JSON.parse(line.slice(Math.max(0, line.indexOf("{"))));
      } catch {
        conn.write("OK\n");
        return;
      }
      calls.push(req);
      const p = req.params || {};
      let result = {};
      if (req.method === "browser.repl.list") result = { sessions };
      else if (req.method === "browser.repl.eval") {
        result = { ok: true, output: [{ level: "log", text: `ran ${String(p.code).length}` }], duration_ms: 1, workspace_id: WORKSPACE };
      } else if (req.method === "browser.repl.reset") result = { session: p.session, existed: true };
      conn.write(JSON.stringify({ id: req.id, ok: true, result }) + "\n");
    });
  });
  return new Promise((resolve) => server.listen(file, () => resolve(server)));
}

function cliEnv(socket) {
  const env = { ...process.env, CMUX_SOCKET_PATH: socket, CMUX_SOCKET: socket, CMUX_CLI_SENTRY_DISABLED: "1", NO_COLOR: "1" };
  delete env.CMUX_WORKSPACE_ID;
  return env;
}

function run(command, args, env) {
  const child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => (stdout += d));
  child.stderr.on("data", (d) => (stderr += d));
  return new Promise((resolve) => child.once("exit", (code) => resolve({ code, stdout, stderr })));
}

// A session's cwd (and any other field) comes from whoever made the
// session; terminal escape sequences in it must not act on the terminal
// of the person who lists sessions.
test("repl list: control characters in a session's fields print visibly", { skip }, async () => {
  const dir = makeTestDir("cmux-repl-cli-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const hostile = "\u001b]52;c;aGk=\u0007\u001b[2J\u009b31m";
  const server = await fakeSocket(socket, calls, [
    { session: `name${hostile}`, idle_seconds: 3, cwd: `/tmp/x${hostile}`, workspace_id: `w${hostile}` },
  ]);
  try {
    for (const args of [["browser", "repl", "list"], ["browser", "repl", "list", "--all-workspaces"]]) {
      const { code, stdout, stderr } = await run(CLI, args, cliEnv(socket));
      assert.equal(code, 0, stderr);
      assert.ok(!/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/.test(stdout), JSON.stringify(stdout));
      assert.match(stdout, /\/tmp\/x␛\]52;c;aGk=␇␛\[2J/);
    }
  } finally {
    server.close();
    removeTestDir(dir);
  }
});

// The interactive REPL reads a terminal one line per cell. A terminal in
// raw mode delivers a line of any length, so the line is bounded like
// `--eval -` and MCP input (15 MiB): a longer one is refused and skipped,
// never buffered whole or sent, and the next line still runs.
test("repl (interactive): a line past the input cap is refused and the next one runs", { skip, timeout: 120000 }, async () => {
  const dir = makeTestDir("cmux-repl-cli-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const server = await fakeSocket(socket, calls, []);
  // A raw-mode pseudo-terminal as stdin, fed a 16 MiB line, then a short one.
  const driver = `
import os, pty, subprocess, sys, tty
master, slave = pty.openpty()
tty.setraw(slave)
child = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=sys.stdout, stderr=sys.stderr)
os.close(slave)
chunk = b"x" * (1 << 20)
for _ in range(16):
    os.write(master, chunk)
os.write(master, b"\\n1+1\\n")
os.close(master)
sys.exit(child.wait())
`;
  try {
    const { stdout, stderr } = await run("python3", ["-c", driver, CLI, "browser", "repl"], cliEnv(socket));
    const evals = calls.filter((c) => c.method === "browser.repl.eval").map((c) => String(c.params.code));
    assert.ok(evals.every((code) => code.length <= 15 * 1024 * 1024), `a ${Math.max(...evals.map((c) => c.length))}-byte line was sent`);
    assert.ok(evals.includes("1+1"), `evals: ${evals.map((c) => c.length)}; stderr: ${stderr.slice(-500)}`);
    assert.match(stderr, /too large/i);
    assert.match(stdout, /ran 3/);
  } finally {
    server.close();
    removeTestDir(dir);
  }
});
