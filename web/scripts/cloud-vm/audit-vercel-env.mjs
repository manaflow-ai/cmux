#!/usr/bin/env node
import { readFileSync } from "node:fs";
import path from "node:path";

import { auditCloudVmProviderCoherence } from "./defaultProviderAudit.mjs";
import { auditFreeProvisioningOverride } from "./freeProvisioningAudit.mjs";
import {
  forbiddenRuntimeEnvKeys,
  legacyCloudVmEnvKeys,
  loadTargetEnv,
  parseBoolean,
  parseWebDirAndTarget,
  recommendedRuntimeEnvKeys,
  requiredRuntimeEnvKeys,
} from "./projects.mjs";

const usage = "Usage: audit-vercel-env.mjs [web-dir] <staging|production> [--strict]";
const { webDir, target, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const strict = rest.includes("--strict") || parseBoolean(process.env.CMUX_CLOUD_VM_ENV_AUDIT_STRICT, false);

try {
  // `target` selects which Vercel PROJECT to audit (staging and production
  // are separate projects: cmux-staging vs cmux). Each project's runtime env
  // is its own "production" environment, so the project object fully encodes
  // the target and the loader needs nothing else.
  const env = loadTargetEnv(project);
  const keys = Object.keys(env).sort();
  const present = new Set(keys);
  const missingRequired = requiredRuntimeEnvKeys.filter((key) => !present.has(key));
  const missingRecommended = recommendedRuntimeEnvKeys.filter((key) => !present.has(key));
  const forbiddenPresent = forbiddenRuntimeEnvKeys.filter((key) => present.has(key));
  const legacyCloudVmPresent = legacyCloudVmEnvKeys.filter((key) => present.has(key));

  // Key presence alone missed the 2026-08-26 outage (stale
  // CMUX_VM_DEFAULT_PROVIDER value): provider VALUES must exist in the image
  // manifest the same deploy ships, for the env-selected default AND for the
  // code default that shipped clients hardcode.
  const manifest = JSON.parse(
    readFileSync(path.join(webDir, "services", "vms", "images", "manifest.json"), "utf8"),
  );
  const providerCoherence = auditCloudVmProviderCoherence(env, manifest);
  // The paid-plan gate is fail-closed by default; a permissive override value
  // in a shared environment is an outage-class misconfiguration, not a note.
  const freeProvisioning = auditFreeProvisioningOverride(env);

  const result = {
    ok: missingRequired.length === 0 &&
      forbiddenPresent.length === 0 &&
      providerCoherence.problems.length === 0 &&
      freeProvisioning.problems.length === 0,
    target,
    project: project.projectName,
    envKeyCount: keys.length,
    envKeys: keys,
    missingRequired,
    missingRecommended,
    forbiddenPresent,
    legacyCloudVmPresent,
    providerCoherence,
    freeProvisioning,
  };

  console.log(JSON.stringify(result, null, 2));
  if (strict && !result.ok) process.exit(1);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
