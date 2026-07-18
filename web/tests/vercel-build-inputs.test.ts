import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import packageJSON from "../package.json";

test("keeps relay catalog validation inside the Vercel project", () => {
  const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const buildCommand = packageJSON.scripts["vercel-build"];
  const scriptPath = buildCommand.match(
    /bun\s+(\S*generate-managed-iroh-relay-catalog\.ts)\s+--check/,
  )?.[1];

  expect(scriptPath).toBeDefined();
  const resolvedScript = resolve(webRoot, scriptPath!);
  expect(resolvedScript.startsWith(`${webRoot}${sep}`)).toBe(true);
  expect(existsSync(resolvedScript)).toBe(true);
});
