// Run with: node --test scripts/lib/reload-shim.test.mjs
//
// These tests execute the shim and pointer writers from reload.sh, covering the
// same discovery paths users invoke. The functions are extracted only to avoid
// sourcing reload.sh (which intentionally starts a build when run as a script);
// the assertions are entirely behavioral.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
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
  const probeStart = source.indexOf("reload_socket_is_live() {");
  const probeEnd = source.indexOf("\n}\n\nreload_cleanup_tag_state_with_lock", probeStart);
  const start = source.indexOf("write_dev_cli_shim() {");
  const end = source.indexOf("\n}\n\nselect_cmux_shim_target", start);
  assert.notEqual(probeStart, -1, "reload.sh must contain the shared socket probe");
  assert.notEqual(probeEnd, -1, "reload.sh socket probe must end before tag cleanup");
  assert.notEqual(start, -1, "reload.sh must contain the shim writer");
  assert.notEqual(end, -1, "reload.sh shim writer must end before target selection");
  return source.slice(probeStart, probeEnd + 2) + "\n" + source.slice(start, end + 2);
}

function pointerWriterSource() {
  const source = fs.readFileSync(reloadScript, "utf8");
  const start = source.indexOf("reload_write_cli_pointer() {");
  const end = source.indexOf("\n}\n\nreload_write_discovery_file", start);
  assert.notEqual(start, -1, "reload.sh must contain the pointer writer");
  assert.notEqual(end, -1, "reload.sh pointer writer must end before the marker writer");
  return source.slice(start, end + 2);
}

function tagStateTransactionSource() {
  const source = fs.readFileSync(reloadScript, "utf8");
  const start = source.indexOf("reload_cleanup_tag_state_with_lock() {");
  const end = source.indexOf("\n}\n\ncleanup_stale_tag_state", start);
  assert.notEqual(start, -1, "reload.sh must contain the tag-state transaction");
  assert.notEqual(end, -1, "reload.sh tag-state transaction must end before cleanup wrapper");
  return source.slice(start, end + 2);
}

function socketProbeSource() {
  const source = fs.readFileSync(reloadScript, "utf8");
  const start = source.indexOf("reload_socket_is_live() {");
  const end = source.indexOf("\n}\n\nreload_cleanup_tag_state_with_lock", start);
  assert.notEqual(start, -1, "reload.sh must contain the shared socket probe");
  assert.notEqual(end, -1, "reload.sh socket probe must end before tag cleanup");
  return source.slice(start, end + 2);
}

function markerDerivationSource() {
  const source = fs.readFileSync(reloadScript, "utf8");
  const start = source.indexOf("derive_socket_marker_names() {");
  const end = source.indexOf("\n}\n\ncleanup_stale_tag_state", start);
  assert.notEqual(start, -1, "reload.sh must derive marker names from the bundle variant");
  assert.notEqual(end, -1, "reload.sh marker derivation must end before stale cleanup");
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

function makeBundle(root, appName, output) {
  const app = path.join(root, `${appName}.app`);
  const cli = path.join(app, "Contents", "Resources", "bin", "cmux");
  fs.mkdirSync(path.dirname(cli), { recursive: true });
  fs.writeFileSync(
    path.join(app, "Contents", "Info.plist"),
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.debug.test</string></dict></plist>",
  );
  writeExecutable(cli, `#!/bin/sh\nprintf '%s\\n' '${output}'\n`);
  return cli;
}

function makeTaggedBundle(root, tag, output) {
  return makeBundle(root, `cmux DEV ${tag}`, output);
}

function runShim(shim, environment, args = ["ping"]) {
  return spawnSync(shim, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: environment,
  });
}

test("reload marker derivation maps a custom bundle ID to stable markers", () => {
  const script = `
sanitize_path() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}
${markerDerivationSource()}
derive_socket_marker_names "$1" "$2"
printf '%s\\n%s\\n' "$CMUX_RELOAD_MARKER_NAME" "$CMUX_RELOAD_TMP_MARKER"
`;
  const result = spawnSync(
    "bash",
    ["-c", script, "reload-marker-variant-test", "com.example.cmux", "custom-tag"],
    { cwd: repoRoot, encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.equal(result.stdout, "last-socket-path\n/tmp/cmux-last-socket-path\n");
});

test("reload pointer publication waits for the shared ownership lock", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-pointer-lock-"));
  const pointer = path.join(root, "last-cli-path");
  const lockPath = `${pointer}.lock`;
  let holder;
  let writer;
  try {
    fs.writeFileSync(pointer, "old-cli\n", { mode: 0o600 });
    holder = spawn(
      "perl",
      [
        "-MFcntl=:DEFAULT",
        "-MFcntl=:flock",
        "-e",
        "$|=1; sysopen(my $fh, $ARGV[0], O_CREAT|O_RDWR|O_NOFOLLOW, 0600) or die $!; flock($fh, LOCK_EX) or die $!; print qq(locked\\n); scalar <STDIN>; flock($fh, LOCK_UN);",
        lockPath,
      ],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    const [holderReady] = await once(holder.stdout, "data");
    assert.equal(holderReady.toString().trim(), "locked");

    const script = `${pointerWriterSource()}\nprintf 'writer-started\\n' >&2\nreload_write_cli_pointer "$1" "$2"\n`;
    writer = spawn(
      "bash",
      ["-c", script, "reload-pointer-test", pointer, "new-cli"],
      { cwd: repoRoot, stdio: ["ignore", "pipe", "pipe"] },
    );
    const [writerReady] = await once(writer.stderr, "data");
    assert.equal(writerReady.toString().trim(), "writer-started");

    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(writer.exitCode, null, "writer must remain blocked behind the held lock");
    assert.equal(fs.readFileSync(pointer, "utf8"), "old-cli\n");

    const writerExit = once(writer, "exit");
    const holderExit = once(holder, "exit");
    holder.stdin.end();
    const [writerStatus] = await writerExit;
    const [holderStatus] = await holderExit;
    assert.equal(holderStatus, 0);
    assert.equal(writerStatus, 0);
    assert.equal(fs.readFileSync(pointer, "utf8"), "new-cli\n");
    assert.equal(fs.statSync(pointer).mode & 0o777, 0o600);
    assert.equal(fs.statSync(lockPath).mode & 0o777, 0o600);
  } finally {
    if (writer?.exitCode === null) writer.kill("SIGKILL");
    if (holder?.exitCode === null) holder.kill("SIGKILL");
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("tag-state publication stays behind the same-tag ownership lock", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-tag-state-lock-"));
  const socketPath = path.join(root, "tag.sock");
  const lockPath = `${socketPath}.lock`;
  const marker = path.join(root, "state", "dev-tag-last-socket-path");
  const legacyMarker = path.join(root, "legacy", "dev-tag-last-socket-path");
  const tmpMarker = path.join(root, "tmp-last-socket-path");
  const pointer = path.join(root, "last-cli-path");
  const cliPath = path.join(root, "cmux DEV tag.app", "Contents", "Resources", "bin", "cmux");
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.mkdirSync(path.dirname(legacyMarker), { recursive: true });
  fs.mkdirSync(path.dirname(cliPath), { recursive: true });
  fs.writeFileSync(marker, "old-socket\n", { mode: 0o600 });
  fs.writeFileSync(legacyMarker, `${socketPath}\n`, { mode: 0o600 });
  fs.writeFileSync(tmpMarker, "old-socket\n", { mode: 0o600 });
  fs.writeFileSync(pointer, "old-cli\n", { mode: 0o600 });
  fs.writeFileSync(cliPath, "#!/bin/sh\n", { mode: 0o755 });

  let holder;
  const runTransaction = (timeout = 3000) => spawnSync(
    "bash",
    [
      "-c",
      `${tagStateTransactionSource()}\nreload_cleanup_tag_state_with_lock "$@"`,
      "reload-tag-state-test",
      socketPath,
      "tag",
      marker,
      legacyMarker,
      tmpMarker,
      pointer,
      socketPath,
      cliPath,
    ],
    { cwd: repoRoot, encoding: "utf8", timeout },
  );

  try {
    holder = spawn(
      "perl",
      [
        "-MFcntl=:DEFAULT",
        "-MFcntl=:flock",
        "-e",
        "$|=1; sysopen(my $fh, $ARGV[0], O_CREAT|O_RDWR|O_NOFOLLOW, 0600) or die $!; flock($fh, LOCK_EX) or die $!; print qq(locked\\n); scalar <STDIN>; flock($fh, LOCK_UN);",
        lockPath,
      ],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    const [holderReady] = await once(holder.stdout, "data");
    assert.equal(holderReady.toString().trim(), "locked");

    const blocked = runTransaction();
    assert.notEqual(blocked.status, 0, blocked.stderr || blocked.stdout);
    assert.equal(fs.readFileSync(marker, "utf8"), "old-socket\n");
    assert.equal(fs.readFileSync(pointer, "utf8"), "old-cli\n");

    const holderExit = once(holder, "exit");
    holder.stdin.end();
    assert.equal((await holderExit)[0], 0);

    const published = runTransaction();
    assert.equal(published.status, 0, published.stderr || published.stdout);
    assert.equal(fs.readFileSync(marker, "utf8"), `${socketPath}\n`);
    assert.equal(fs.readFileSync(tmpMarker, "utf8"), `${socketPath}\n`);
    assert.equal(fs.readFileSync(pointer, "utf8"), `${cliPath}\n`);
    assert.equal(fs.existsSync(legacyMarker), false);
    assert.equal(fs.existsSync(lockPath), false);
  } finally {
    if (holder?.exitCode === null) holder.kill("SIGKILL");
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload socket probe treats a bounded probe timeout as protected", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-probe-timeout-"));
  const fakeBin = path.join(root, "bin");
  const socketPath = path.join(root, "probe.sock");
  fs.mkdirSync(fakeBin, { recursive: true });
  writeExecutable(
    path.join(fakeBin, "perl"),
    "#!/bin/sh\ncase \"$*\" in *IO::Select*) exit 0 ;; *) sleep 10; exit 1 ;; esac\n",
  );
  writeExecutable(path.join(fakeBin, "nc"), "#!/bin/sh\nsleep 10\n");
  const server = net.createServer();
  try {
    server.listen(socketPath);
    await once(server, "listening");
    const started = Date.now();
    const result = spawnSync(
      "bash",
      ["-c", `${socketProbeSource()}\nreload_socket_is_live "$1"`, "reload-probe-timeout", socketPath],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: { PATH: `${fakeBin}:/usr/bin:/bin` },
        timeout: 3000,
      },
    );
    const elapsed = Date.now() - started;
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.error, undefined);
    assert.ok(elapsed < 2500, `probe exceeded its deadline: ${elapsed}ms`);
  } finally {
    server.close();
    await once(server, "close").catch(() => {});
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload tag-state liveness probe bounds a full Unix-socket backlog", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-wedged-socket-"));
  const socketPath = path.join(root, "wedged.sock");
  const marker = path.join(root, "marker");
  const legacyMarker = path.join(root, "legacy-marker");
  const tmpMarker = path.join(root, "tmp-marker");
  const pointer = path.join(root, "pointer");
  fs.writeFileSync(marker, "keep-marker\n", { mode: 0o600 });
  fs.writeFileSync(pointer, "keep-pointer\n", { mode: 0o600 });

  // Keep a listener alive without accepting. The non-blocking clients fill the
  // kernel backlog, which makes a blocking connect() hang indefinitely.
  const wedge = spawn(
    "perl",
    [
      "-MFcntl=:DEFAULT",
      "-MSocket",
      "-MErrno=EAGAIN,EWOULDBLOCK,EINPROGRESS",
      "-e",
      [
        "my $path = shift; unlink($path);",
        "socket(my $listener, PF_UNIX, SOCK_STREAM, 0) or die $!;",
        "bind($listener, sockaddr_un($path)) or die $!; listen($listener, 1) or die $!;",
        "my @clients; for (1 .. 512) { socket(my $client, PF_UNIX, SOCK_STREAM, 0) or next;",
        "my $flags = fcntl($client, F_GETFL, 0); fcntl($client, F_SETFL, $flags | O_NONBLOCK) if defined $flags;",
        "connect($client, sockaddr_un($path)); push @clients, $client; }",
        "$|=1; print qq(ready\\n); scalar <STDIN>;",
      ].join(" "),
      socketPath,
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  try {
    const [ready] = await once(wedge.stdout, "data");
    assert.equal(ready.toString().trim(), "ready");
    const started = Date.now();
    const result = spawnSync(
      "bash",
      [
        "-c",
        `${tagStateTransactionSource()}\nreload_cleanup_tag_state_with_lock "$@"`,
        "reload-wedged-test",
        socketPath,
        "wedged",
        marker,
        legacyMarker,
        tmpMarker,
        pointer,
      ],
      { cwd: repoRoot, encoding: "utf8", timeout: 5000 },
    );
    const elapsed = Date.now() - started;
    assert.notEqual(result.error?.code, "ETIMEDOUT", "probe must not block forever");
    assert.ok(elapsed < 4500, `liveness probe took ${elapsed}ms`);
    // Darwin reports ECONNREFUSED immediately once this synthetic backlog is
    // saturated, while other kernels leave connect() pending until the poll
    // deadline. Both outcomes are valid for this fixture; the dedicated probe
    // test above supplies the deterministic timeout/protection assertion.
    if (result.status !== 0) {
      assert.equal(fs.readFileSync(marker, "utf8"), "keep-marker\n");
      assert.equal(fs.readFileSync(pointer, "utf8"), "keep-pointer\n");
    }
  } finally {
    wedge.stdin.end();
    await once(wedge, "exit").catch(() => {});
    try { fs.unlinkSync(socketPath); } catch {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});

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
  const tag = `shim-live-${crypto.randomUUID()}`;
  const socketPath = `/tmp/cmux-debug-${tag}.sock`;
  let server;
  try {
    try { fs.unlinkSync(socketPath); } catch {}
    server = net.createServer((connection) => {
      connection.on("data", () => connection.end());
    });
    server.listen(socketPath);
    await once(server, "listening");

    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, tag, "tagged");
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
    try { fs.unlinkSync(socketPath); } catch {}
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

test("reload shim preserves a non-reload-managed bundled CLI", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-bundled-"));
  try {
    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const bundledCLI = makeBundle(root, "cmux NIGHTLY", "nightly");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable\\n'\n");
    generateShim(shim, fallback, pointer);

    const environment = cleanEnvironment(root);
    environment.CMUX_BUNDLED_CLI_PATH = bundledCLI;
    const result = runShim(shim, environment);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "nightly");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload shim falls through when a reload-managed bundled CLI is dead", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-bundled-dead-"));
  try {
    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const bundledCLI = makeTaggedBundle(root, `shim-dead-${crypto.randomUUID()}`, "tagged");
    writeExecutable(fallback, "#!/bin/sh\nprintf 'stable\\n'\n");
    generateShim(shim, fallback, pointer);

    const environment = cleanEnvironment(root);
    environment.CMUX_BUNDLED_CLI_PATH = bundledCLI;
    const result = runShim(shim, environment);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "stable");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("reload shim keeps an explicit --socket pinned even when the pointer target is live", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-reload-shim-explicit-flag-"));
  const tag = `shim-explicit-live-${crypto.randomUUID()}`;
  const socketPath = `/tmp/cmux-debug-${tag}.sock`;
  let server;
  try {
    try { fs.unlinkSync(socketPath); } catch {}
    server = net.createServer((connection) => {
      connection.on("data", () => connection.end());
    });
    server.listen(socketPath);
    await once(server, "listening");

    const pointer = path.join(root, "last-cli-path");
    const shim = path.join(root, "cmux");
    const fallback = path.join(root, "stable-cmux");
    const taggedCLI = makeTaggedBundle(root, tag, "tagged");
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
    try { fs.unlinkSync(socketPath); } catch {}
    fs.rmSync(root, { recursive: true, force: true });
  }
});
