#!/usr/bin/env node
"use strict";
const {spawnSync} = require("child_process");
const packages = {
  "darwin-arm64": "cmux-relay-darwin-arm64", "darwin-x64": "cmux-relay-darwin-x64",
  "linux-x64": "cmux-relay-linux-x64", "linux-arm64": "cmux-relay-linux-arm64",
  "win32-x64": "cmux-relay-win32-x64",
};
const pkg = packages[`${process.platform}-${process.arch}`];
if (!pkg) { console.error(`cmux-relay: no prebuilt binary for ${process.platform}-${process.arch}`); process.exit(1); }
const bin = process.platform === "win32" ? "cmux-relay.exe" : "cmux-relay";
let path;
try { path = require.resolve(`${pkg}/bin/${bin}`); }
catch { console.error(`cmux-relay: platform package ${pkg} is not installed`); process.exit(1); }
const result = spawnSync(path, process.argv.slice(2), {stdio: "inherit"});
if (result.error) { console.error(`cmux-relay: failed to launch ${path}: ${result.error.message}`); process.exit(1); }
process.exit(result.status === null ? 1 : result.status);
