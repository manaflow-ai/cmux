#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const [version, target, binary, outputRoot] = process.argv.slice(2);
if (!version || !target || !binary || !outputRoot) {
  console.error("usage: package-npm.mjs <version> <npm-target> <binary> <output-root>");
  process.exit(2);
}

const packageName = `@coderouter/cli-${target}`;
const directory = path.join(outputRoot, `cli-${target}`);
fs.rmSync(directory, { recursive: true, force: true });
fs.mkdirSync(path.join(directory, "bin"), { recursive: true });
const executableName = target.startsWith("win32-") ? "coderouter.exe" : "coderouter";
fs.copyFileSync(binary, path.join(directory, "bin", executableName));
if (!target.startsWith("win32-")) {
  fs.chmodSync(path.join(directory, "bin", executableName), 0o755);
}
fs.writeFileSync(
  path.join(directory, "package.json"),
  `${JSON.stringify(
    {
      name: packageName,
      version,
      license: "MIT",
      os: [target.split("-")[0]],
      cpu: [target.split("-")[1]],
      files: ["bin"],
    },
    null,
    2,
  )}\n`,
);

