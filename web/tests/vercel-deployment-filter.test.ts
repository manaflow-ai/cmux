import { expect, test } from "bun:test";

import docsVercelConfig from "../vercel.docs-channel.json";
import vercelConfig from "../vercel.json";

function deploymentEnabled(
  branch: string,
  rules: Record<string, boolean>,
): boolean {
  const matchingRules = [rules[branch], rules["**"]].filter(
    (rule): rule is boolean => rule !== undefined,
  );

  return matchingRules.length === 0 || matchingRules.includes(true);
}

test("automatically deploys main but skips ephemeral branches", () => {
  for (const config of [vercelConfig, docsVercelConfig]) {
    expect(config.git.deploymentEnabled).toEqual({
      main: true,
      "**": false,
    });

    const deploymentRules: Record<string, boolean> =
      config.git.deploymentEnabled;
    expect(deploymentEnabled("main", deploymentRules)).toBe(true);

    for (const branch of [
      "codex/refresh-generated-assets",
      "reload-blacksmith/dsfix-123",
      "reload-build/dsfix-123",
      "gate/dsfix-123",
    ]) {
      expect(deploymentEnabled(branch, deploymentRules)).toBe(false);
    }
  }
});
