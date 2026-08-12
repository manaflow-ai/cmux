// Run with: node --test scripts/lib/reload-shim.test.mjs
//
// These tests execute the shim writer from reload.sh and then run the generated
// command, so they cover the same pointer/socket validation path users invoke.
// The writer is extracted only to avoid sourcing reload.sh (which intentionally
// starts a build when run as a script); the assertions are entirely behavioral.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const reloadScript = path.join(repoRoot, "scripts/reload.sh");

function shimWriterSource() {
  const source = fs.readFileSync(reloadScript, "utf8");
  const start = source.indexOf("write_dev_cli_shim() {");
  const end = source.indexOf("\n}\n\nselect_cmux_shim_target", start);
  assert.notEqual(start, -1, "reload.sh must contain the shim writer");
  assert.notEqual(end, -1, "reload.sh shim writer must end before target selection");
  return source.slice(start, end + 2);
}

function writeExecutable(filePath, contents) {
  fs.writeFileSync(filePath, contents, { mode: 0o755 });
  fs.chmodSync(filePath, 0o755);
}

function generateShim(target, fallback, pointerPath) {
  const script = `${shimWriterSource()}\nwrite_dev_cli_shim "$1" "$2" "$3"\n`;
  const result = spawnSync(
    "bash",
    ["-c", script, "reload-shim-test", target, fallback, pointerPath],
    { cwd: repoRoot, encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

function cleanEnvironment(home) {
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith("CMUX_")),
  );
  environment.HOME = home;
  environment.PATH = "/usr/bin:/bin";
  return environment;
}

function makeTaggedBundle(root, tag, output) {
  const app = path.join(root, `cmux DEV ${tag}.app`);
  const cli = path.join(app, "Contents", "Resources", "bin", "cmux");
  fs.mkdirSync(path.dirname(cli), { recursive: true });
  fs.writeFileSync(
    path.join(app, "Contents", "Info.plist"),
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.debug.test</string></dict></plist>",
  );
  writeExecutable(cli, `#!/bin/sh\nprintf '%s\\n' '${output}'\n`);
  return cli;
}

function runShim(shim, environment, args = ["ping"]) {
  return spawnSync(shim, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: environment,
  });
}

test("reload shim skips a stale pointer target and falls through to stable CLI", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-stale-"));
  try {
    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, "shim-stale", "tagged");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable\\n'\n");
    fs.writeFileSync(pointer, `${taggedCLI}\n`, { mode: 0o600 });
    generateShim(shim, fallback, pointer);

    const result = runShim(shim, cleanEnvironment(root));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "stable");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload shim delegates to a pointer target only while its socket is live", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-live-"));
  const socketPath = "/tmp/cmux-debug-shim-live.sock";
  let server;
  try {
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    server = net.createServer((connection) => {
      connection.on("data", () => connection.end());
    });
    server.listen(socketPath);
    await once(server, "listening");

    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, "shim-live", "tagged");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable\\n'\n");
    fs.writeFileSync(pointer, `${taggedCLI}\n`, { mode: 0o600 });
    generateShim(shim, fallback, pointer);

    const result = runShim(shim, cleanEnvironment(root));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "tagged");
  } finally {
    if (server) {
      server.close();
      await once(server, "close");
    }
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload shim does not let an explicit socket use a stale pointer", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-explicit-"));
  try {
    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, "shim-explicit", "tagged");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable:%s\\n' \"$CMUX_SOCKET_PATH\"\n");
    fs.writeFileSync(pointer, `${taggedCLI}\n`, { mode: 0o600 });
    generateShim(shim, fallback, pointer);

    const environment = cleanEnvironment(root);
    const pinnedSocket = path.join(root, "pinned.sock");
    environment.CMUX_SOCKET_PATH = pinnedSocket;
    const result = runShim(shim, environment);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), `stable:${pinnedSocket}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload shim keeps an explicit --socket pinned even when the pointer target is live", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-explicit-flag-"));
  const socketPath = "/tmp/cmux-debug-shim-explicit-live.sock";
  let server;
  try {
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    server = net.createServer((connection) => {
      connection.on("data", () => connection.end());
    });
    server.listen(socketPath);
    await once(server, "listening");

    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, "shim-explicit-live", "tagged");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable:%s\\n' \"$2\"\n");
    fs.writeFileSync(pointer, `${taggedCLI}\n`, { mode: 0o600 });
    generateShim(shim, fallback, pointer);

    const environment = cleanEnvironment(root);
    const pinnedSocket = path.join(root, "pinned.sock");
    const result = runShim(shim, environment, ["--socket", pinnedSocket, "ping"]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), `stable:${pinnedSocket}`);
  } finally {
    if (server) {
      server.close();
      await once(server, "close");
    }
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
});
