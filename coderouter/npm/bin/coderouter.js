#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const platform = process.platform;
const arch = process.arch;
const supported = new Set([
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "linux-arm64",
  "win32-x64",
]);
const target = `${platform}-${arch}`;
if (!supported.has(target)) {
  console.error(`coderouter does not provide a binary for ${target}.`);
  process.exit(1);
}

const executable = path.join(
  path.dirname(__dirname),
  "vendor",
  target,
  platform === "win32" ? "coderouter.exe" : "coderouter",
);
if (!require("node:fs").existsSync(executable)) {
  console.error(
    `coderouter's ${target} executable is missing. Reinstall coderouter.`,
  );
  process.exit(1);
}
const result = spawnSync(executable, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
