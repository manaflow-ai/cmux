#!/usr/bin/env node
"use strict";
const { spawnSync } = require("child_process");

// `npx` puts package installs below a cache directory named `_npx`. That
// directory is disposable, so a login task or launch agent must never point
// at a binary below it. The native relay repeats this check for direct binary
// invocations; keeping it here gives npm users an immediate, actionable error.
const EPHEMERAL_NPX_MESSAGE =
  "cmux-relay: --autostart needs a durable executable; npx is using a temporary cache. " +
  "Install cmux-relay globally (npm install --global cmux-relay) or in a persistent project, " +
  "then run cmux-relay --autostart.";

function isEphemeralNpxPath(value) {
  return value
    .split(/[\\/]+/)
    .some((component) => component.toLowerCase() === "_npx");
}

const packages = {
  "darwin-arm64": "cmux-relay-darwin-arm64",
  "darwin-x64": "cmux-relay-darwin-x64",
  "linux-x64": "cmux-relay-linux-x64",
  "linux-arm64": "cmux-relay-linux-arm64",
  "win32-x64": "cmux-relay-win32-x64",
};
const pkg = packages[`${process.platform}-${process.arch}`];
if (!pkg) {
  console.error(`cmux-relay: no prebuilt binary for ${process.platform}-${process.arch}`);
  process.exit(1);
}
const bin = process.platform === "win32" ? "cmux-relay.exe" : "cmux-relay";
let path;
try { path = require.resolve(`${pkg}/bin/${bin}`); }
catch {
  console.error(`cmux-relay: platform package ${pkg} is not installed`);
  process.exit(1);
}
if (process.argv.slice(2).includes("--autostart") && isEphemeralNpxPath(path)) {
  console.error(EPHEMERAL_NPX_MESSAGE);
  process.exit(2);
}
const result = spawnSync(path, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(`cmux-relay: failed to launch ${path}: ${result.error.message}`);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status === null ? 1 : result.status);
