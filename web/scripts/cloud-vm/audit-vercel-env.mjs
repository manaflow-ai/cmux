#!/usr/bin/env node
import {
  forbiddenRuntimeEnvKeys,
  legacyCloudVmEnvKeys,
  nonBlankRequiredRuntimeEnvKeys,
  parseBoolean,
  parseWebDirAndTarget,
  pullProductionEnv,
  recommendedRuntimeEnvKeys,
  requiredRuntimeEnvKeys,
} from "./projects.mjs";

const usage = "Usage: audit-vercel-env.mjs [web-dir] <staging|production> [--strict]";
const { target, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const strict = rest.includes("--strict") || parseBoolean(process.env.CMUX_CLOUD_VM_ENV_AUDIT_STRICT, false);

try {
  const env = pullProductionEnv(project);
  const keys = Object.keys(env).sort();
  const present = new Set(keys);
  const nonBlankRequired = new Set(nonBlankRequiredRuntimeEnvKeys);
  const missingRequired = requiredRuntimeEnvKeys.filter((key) => {
    if (!present.has(key)) return true;
    return nonBlankRequired.has(key) && !hasNonBlankEnvValue(env, key);
  });
  const missingRecommended = recommendedRuntimeEnvKeys.filter((key) => !present.has(key));
  const forbiddenPresent = forbiddenRuntimeEnvKeys.filter((key) => present.has(key));
  const legacyCloudVmPresent = legacyCloudVmEnvKeys.filter((key) => present.has(key));

  const result = {
    ok: missingRequired.length === 0 && forbiddenPresent.length === 0,
    target,
    project: project.projectName,
    envKeyCount: keys.length,
    envKeys: keys,
    missingRequired,
    missingRecommended,
    forbiddenPresent,
    legacyCloudVmPresent,
  };

  console.log(JSON.stringify(result, null, 2));
  if (strict && !result.ok) process.exit(1);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

function hasNonBlankEnvValue(env, key) {
  const value = env[key];
  return typeof value === "string" && value.trim().length > 0;
}
