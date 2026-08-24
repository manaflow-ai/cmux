#!/usr/bin/env node
"use strict";

// Launcher for `npx cmux` / a global `cmux` install. The actual TUI is a
// prebuilt Rust binary shipped in a per-platform optional dependency
// (cmux-tui-<platform>); npm installs only the one matching os+cpu. This shim
// resolves that binary and execs it, forwarding argv, stdio, exit code, and
// signals so cmux behaves exactly like the native binary.

const { spawnSync } = require("child_process");

const PACKAGE_BY_PLATFORM = {
  "darwin-arm64": "cmux-tui-darwin-arm64",
  "darwin-x64": "cmux-tui-darwin-x64",
  "linux-x64": "cmux-tui-linux-x64",
  "linux-arm64": "cmux-tui-linux-arm64",
  // win32-x64 pending: ghostty vt headers fail bindgen under mingw clang.
};

const key = `${process.platform}-${process.arch}`;
const pkg = PACKAGE_BY_PLATFORM[key];

if (!pkg) {
  console.error(
    `cmux: no prebuilt binary for ${key}. Supported: ${Object.keys(PACKAGE_BY_PLATFORM).join(", ")}.`
  );
  process.exit(1);
}

const binName = process.platform === "win32" ? "cmux-tui.exe" : "cmux-tui";

let binPath;
try {
  binPath = require.resolve(`${pkg}/bin/${binName}`);
} catch {
  console.error(
    `cmux: platform package ${pkg} is not installed. Reinstall cmux, ` +
      `or set npm to install optional dependencies (--include=optional).`
  );
  process.exit(1);
}

const result = spawnSync(binPath, process.argv.slice(2), { stdio: "inherit" });

if (result.error) {
  console.error(`cmux: failed to launch ${binPath}: ${result.error.message}`);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
  return;
}
process.exit(result.status === null ? 1 : result.status);
