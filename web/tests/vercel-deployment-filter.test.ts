import { expect, test } from "bun:test";

import vercelConfig from "../vercel.json";

const deploymentRules = vercelConfig.git.deploymentEnabled;

function matchesVercelPattern(pattern: string, branch: string): boolean {
  const regex = pattern
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replaceAll("**", "\0")
    .replaceAll("*", "[^/]*")
    .replaceAll("\0", ".*");

  return new RegExp(`^${regex}$`).test(branch);
}

function deploymentEnabled(branch: string): boolean {
  const matchingRules = Object.entries(deploymentRules)
    .filter(([pattern]) => matchesVercelPattern(pattern, branch))
    .map(([, enabled]) => enabled);

  return matchingRules.length === 0 || matchingRules.includes(true);
}

test("automatically deploys main but skips ephemeral branches", () => {
  expect(deploymentEnabled("main")).toBe(true);

  for (const branch of [
    "codex/refresh-generated-assets",
    "reload-blacksmith/dsfix-123",
    "reload-build/dsfix-123",
    "gate/dsfix-123",
  ]) {
    expect(deploymentEnabled(branch)).toBe(false);
  }
});
