// `cmux browser repl mcp`: an MCP client handshake against the built CLI.
// The CLI talks to a fake control socket that answers `browser.repl.eval`
// and `browser.repl.reset` the way the app does, so no app is needed; the
// test checks the JSON-RPC exchange and the socket calls each tool makes.
//
//   PARITY_CMUX_CLI=<built cmux CLI> node --test tests/browser-parity/unit/mcp.test.mjs
// Skipped without PARITY_CMUX_CLI.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const CLI = process.env.PARITY_CMUX_CLI;
const BOUND_WORKSPACE = "11111111-2222-3333-4444-555555555555";
const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489", "hex").toString("base64");

function fakeSocket(file, calls) {
  const server = net.createServer((conn) => {
    const lines = readline.createInterface({ input: conn });
    lines.on("line", (line) => {
      let req;
      try {
        // A CLI run inside cmux prefixes the request with its capability token.
        req = JSON.parse(line.slice(Math.max(0, line.indexOf("{"))));
      } catch {
        conn.write("OK\n");
        return;
      }
      calls.push(req);
      const p = req.params || {};
      let result = {};
      if (req.method === "browser.repl.eval") {
        const code = String(p.code);
        let output = [{ level: "log", text: `ran: ${code}` }];
        if (code.includes("cmux-mcp-image:")) output = [{ level: "log", text: `cmux-mcp-image:${PNG}` }];
        // The app answers with the workspace it bound the session to.
        result = { ok: !code.includes("throw"), output, duration_ms: 3, workspace_id: BOUND_WORKSPACE };
        if (code.includes("throw")) result.error = "Error: boom";
      } else if (req.method === "browser.repl.reset") {
        result = { session: p.session, existed: true };
      }
      conn.write(JSON.stringify({ id: req.id, ok: true, result }) + "\n");
    });
  });
  return new Promise((resolve) => server.listen(file, () => resolve(server)));
}

test("repl mcp: handshake, tools/list and each tool over the REPL socket methods", { skip: !CLI && "set PARITY_CMUX_CLI" }, async () => {
  const dir = makeTestDir("cmux-mcp-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const server = await fakeSocket(socket, calls);
  const env = { ...process.env, CMUX_SOCKET_PATH: socket, CMUX_SOCKET: socket, CMUX_CLI_SENTRY_DISABLED: "1" };
  delete env.CMUX_WORKSPACE_ID;
  const child = spawn(CLI, ["browser", "repl", "mcp", "--session", "t1"], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  const replies = new Map();
  const waiters = new Map();
  const nonJSON = [];
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      nonJSON.push(line);
      return;
    }
    replies.set(msg.id, msg);
    waiters.get(msg.id)?.(msg);
  });
  let next = 0;
  const request = (method, params) => {
    const id = ++next;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no reply to ${method}; stderr: ${stderr}`)), 15000);
      waiters.set(id, (m) => {
        clearTimeout(timer);
        resolve(m);
      });
    });
  };
  try {
    const init = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    assert.equal(init.jsonrpc, "2.0");
    assert.equal(init.result.protocolVersion, "2025-06-18");
    assert.ok(init.result.capabilities.tools);
    assert.equal(init.result.serverInfo.name, "cmux-browser-repl");
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    // An unknown protocol version gets the newest supported one.
    assert.equal((await request("initialize", { protocolVersion: "1999-01-01" })).result.protocolVersion, "2025-06-18");

    const list = await request("tools/list", {});
    assert.deepEqual(list.result.tools.map((t) => t.name), ["eval", "snapshot", "screenshot", "tabs", "reset"]);
    assert.deepEqual(list.result.tools[0].inputSchema.required, ["code"]);

    const evalReply = await request("tools/call", { name: "eval", arguments: { code: "const a = 1; a + 1" } });
    assert.equal(evalReply.result.isError, false);
    assert.equal(evalReply.result.content[0].type, "text");
    assert.match(evalReply.result.content[0].text, /^ran: const a = 1; a \+ 1\n\[ok \| 3ms\]$/);

    const failed = await request("tools/call", { name: "eval", arguments: { code: "throw new Error('boom')" } });
    assert.equal(failed.result.isError, true);
    assert.match(failed.result.content[0].text, /Error: boom/);

    const snap = await request("tools/call", { name: "snapshot", arguments: { target: "e\"1", interactive: true } });
    assert.match(snap.result.content[0].text, /ran: await snapshot\("e\\"1", \{ interactive: true, viewport: false \}\)/);

    const shot = await request("tools/call", { name: "screenshot", arguments: { fullPage: true } });
    assert.deepEqual(shot.result.content, [{ type: "image", data: PNG, mimeType: "image/png" }]);

    assert.match((await request("tools/call", { name: "tabs", arguments: {} })).result.content[0].text, /tabs\.list\(\)/);
    assert.match((await request("tools/call", { name: "reset", arguments: {} })).result.content[0].text, /t1/);

    assert.deepEqual((await request("ping")).result, {});
    assert.equal((await request("tools/call", { name: "nope", arguments: {} })).error.code, -32602);
    assert.equal((await request("resources/list", {})).error.code, -32601);

    const evals = calls.filter((c) => c.method === "browser.repl.eval");
    assert.equal(evals.length, 5);
    assert.ok(evals.every((c) => c.params.session === "t1"), "every tool runs in the --session");
    assert.equal(evals.find((c) => c.params.code.includes("cmux-mcp-image:")).params.max_output, 0, "a screenshot is not cut by the output cap");
    assert.deepEqual(calls.filter((c) => c.method === "browser.repl.reset").map((c) => c.params.session), ["t1"]);
    assert.deepEqual(nonJSON, [], "stdout carries only JSON-RPC");
  } finally {
    child.stdin.end();
    await new Promise((r) => child.once("exit", r));
    server.close();
    removeTestDir(dir);
  }
});

// One MCP server process: requests over stdio, replies by id.
function startServer(args, env) {
  const child = spawn(CLI, ["browser", "repl", "mcp", ...args], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  const waiters = new Map();
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    try {
      const msg = JSON.parse(line);
      waiters.get(msg.id)?.(msg);
    } catch {}
  });
  let next = 0;
  const request = (method, params) => {
    const id = ++next;
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no reply to ${method}; stderr: ${stderr}`)), 15000);
      waiters.set(id, (m) => {
        clearTimeout(timer);
        resolve(m);
      });
    });
  };
  const stop = () => {
    if (child.exitCode !== null) return Promise.resolve();
    child.stdin.end();
    return new Promise((r) => child.once("exit", r));
  };
  return { child, request, stop };
}

test("repl mcp: without --session each server process gets its own session", { skip: !CLI && "set PARITY_CMUX_CLI" }, async () => {
  const dir = makeTestDir("cmux-mcp-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const server = await fakeSocket(socket, calls);
  const env = { ...process.env, CMUX_SOCKET_PATH: socket, CMUX_SOCKET: socket, CMUX_CLI_SENTRY_DISABLED: "1" };
  delete env.CMUX_WORKSPACE_ID;
  const servers = [startServer([], env), startServer([], env)];
  try {
    const sessions = [];
    for (const s of servers) {
      await s.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
      await s.request("tools/call", { name: "eval", arguments: { code: "1" } });
      const before = calls.length;
      const reset = await s.request("tools/call", { name: "reset", arguments: {} });
      const resetCall = calls.slice(before).find((c) => c.method === "browser.repl.reset");
      sessions.push({ eval: calls.filter((c) => c.method === "browser.repl.eval").at(-1).params.session, reset: resetCall.params.session, text: reset.result.content[0].text });
    }
    for (const [i, s] of sessions.entries()) {
      assert.match(s.eval, new RegExp(`^mcp-${servers[i].child.pid}-[a-z0-9]+$`), "the default session names this server process");
      assert.equal(s.reset, s.eval, "reset targets the same session");
      assert.ok(s.text.includes(s.eval));
    }
    assert.notEqual(sessions[0].eval, sessions[1].eval, "two clients without --session do not share a session");
    // Nobody else can reach a server's own session, so it ends with the server.
    const before = calls.length;
    await Promise.all(servers.map((s) => s.stop()));
    assert.deepEqual(calls.slice(before).filter((c) => c.method === "browser.repl.reset").map((c) => c.params.session).sort(), sessions.map((s) => s.eval).sort());
  } finally {
    await Promise.all(servers.map((s) => s.stop()));
    server.close();
    removeTestDir(dir);
  }
});

test("repl mcp: later calls name the workspace the first call bound", { skip: !CLI && "set PARITY_CMUX_CLI" }, async () => {
  const dir = makeTestDir("cmux-mcp-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const server = await fakeSocket(socket, calls);
  const env = { ...process.env, CMUX_SOCKET_PATH: socket, CMUX_SOCKET: socket, CMUX_CLI_SENTRY_DISABLED: "1" };
  delete env.CMUX_WORKSPACE_ID;
  const s = startServer([], env);
  try {
    await s.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    await s.request("tools/call", { name: "eval", arguments: { code: "1" } });
    await s.request("tools/call", { name: "eval", arguments: { code: "2" } });
    await s.request("tools/call", { name: "reset", arguments: {} });
    const [first, second] = calls.filter((c) => c.method === "browser.repl.eval");
    assert.equal(first.params.workspace_id, undefined, "the first call lets the app choose");
    assert.equal(second.params.workspace_id, BOUND_WORKSPACE);
    assert.equal(calls.find((c) => c.method === "browser.repl.reset").params.workspace_id, BOUND_WORKSPACE);
  } finally {
    await s.stop();
    server.close();
    removeTestDir(dir);
  }
});

// A line longer than the CLI's input cap (15 MiB, as --eval) is refused with
// a JSON-RPC error instead of being buffered whole; the server goes on.
test("repl mcp: an oversized line fails with a JSON-RPC error and the server keeps serving", { skip: !CLI && "set PARITY_CMUX_CLI" }, async () => {
  const dir = makeTestDir("cmux-mcp-");
  const socket = path.join(dir, "s.sock");
  const calls = [];
  const server = await fakeSocket(socket, calls);
  const env = { ...process.env, CMUX_SOCKET_PATH: socket, CMUX_SOCKET: socket, CMUX_CLI_SENTRY_DISABLED: "1" };
  delete env.CMUX_WORKSPACE_ID;
  const s = startServer(["--session", "big"], env);
  const errors = [];
  readline.createInterface({ input: s.child.stdout }).on("line", (line) => {
    try {
      const msg = JSON.parse(line);
      if (msg.id === null && msg.error) errors.push(msg.error);
    } catch {}
  });
  try {
    await s.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    const code = "x".repeat(16 * 1024 * 1024);
    s.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 99, method: "tools/call", params: { name: "eval", arguments: { code } } }) + "\n");
    // Replies come in order: the refusal is out before the next request's reply.
    const list = await s.request("tools/list", {});
    assert.ok(list.result.tools.length > 0, "the server still answers");
    assert.equal(errors.length, 1, "one error for the oversized line");
    assert.equal(errors[0].code, -32600);
    assert.match(errors[0].message, /too large/);
    assert.equal(calls.filter((c) => c.method === "browser.repl.eval").length, 0, "the oversized request never reached the app");
  } finally {
    await s.stop();
    server.close();
    removeTestDir(dir);
  }
});
