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
};
const platformKey = `${process.platform}-${process.arch}`;
// The Rust machine relay has no Windows PTY backend. Do not resolve an
// optional package, download a binary, or fall back to a shell on Windows.
if (process.platform === "win32") {
  console.error(
    "cmux-relay: unsupported_platform (the Rust machine relay requires a Unix PTY backend)."
  );
  process.exit(1);
}
const pkg = packages[platformKey];
if (!pkg) {
  console.error(`cmux-relay: unsupported_platform (no Unix binary for ${platformKey}).`);
  process.exit(1);
}
const bin = "chatmux-relay";
const runtimeBin = process.platform === "win32" ? "cmux-tui.exe" : "cmux-tui";
let relayPath;
let runtimePath;
try {
  relayPath = require.resolve(`${pkg}/bin/${bin}`);
  // Each relay target package bundles the exact cmux-tui runtime built from
  // the same checkout. Resolve it from that package so a clean install never
  // depends on a separately published TUI package or silently falls back.
  runtimePath = require.resolve(`${pkg}/bin/${runtimeBin}`);
}
catch {
  console.error(
    `cmux-relay: platform package ${pkg} with its cmux-tui runtime is required; ` +
      "reinstall cmux-relay with optional dependencies enabled"
  );
  process.exit(1);
}
if (process.argv.slice(2).includes("--autostart") && isEphemeralNpxPath(relayPath)) {
  console.error(EPHEMERAL_NPX_MESSAGE);
  process.exit(2);
}
const env = { ...process.env, CHATMUX_RELAY_CMUX_TUI: runtimePath };
const result = spawnSync(relayPath, process.argv.slice(2), { stdio: "inherit", env });
if (result.error) {
  console.error(`cmux-relay: failed to launch ${relayPath}: ${result.error.message}`);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status === null ? 1 : result.status);
