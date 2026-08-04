#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const platform = process.platform;
const arch = process.arch;
const supported = new Set([
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "win32-x64",
]);
const target = `${platform}-${arch}`;
if (!supported.has(target)) {
  console.error(`CodeRouter does not provide a binary for ${target}.`);
  process.exit(1);
}

const packageName = `@coderouter/cli-${target}`;
let packageJson;
try {
  packageJson = require.resolve(`${packageName}/package.json`);
} catch {
  console.error(
    `CodeRouter's platform package ${packageName} is missing. ` +
      "Reinstall coderouter and ensure optional dependencies are enabled.",
  );
  process.exit(1);
}

const executable = path.join(
  path.dirname(packageJson),
  "bin",
  platform === "win32" ? "coderouter.exe" : "coderouter",
);
const result = spawnSync(executable, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
