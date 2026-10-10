#!/usr/bin/env node

import fs from "node:fs";

const cargo = fs.readFileSync(new URL("../Cargo.toml", import.meta.url), "utf8");
const pyproject = fs.readFileSync(new URL("../pyproject.toml", import.meta.url), "utf8");
const npm = JSON.parse(
  fs.readFileSync(new URL("../npm/package.json", import.meta.url), "utf8"),
);

const cargoVersion = cargo.match(/^version = "([^"]+)"$/m)?.[1];
const pythonVersion = pyproject.match(/^version = "([^"]+)"$/m)?.[1];
const versions = new Set([cargoVersion, pythonVersion, npm.version]);
if (versions.size !== 1 || versions.has(undefined)) {
  console.error(
    `coderouter versions differ: cargo=${cargoVersion} python=${pythonVersion} npm=${npm.version}`,
  );
  process.exit(1);
}
for (const [name, version] of Object.entries(npm.optionalDependencies ?? {})) {
  if (version !== npm.version) {
    console.error(`${name} is ${version}, expected ${npm.version}`);
    process.exit(1);
  }
}
console.log(npm.version);
