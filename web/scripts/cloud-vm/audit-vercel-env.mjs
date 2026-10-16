#!/usr/bin/env node
import { readFileSync } from "node:fs";
import path from "node:path";

import { auditAlertSink } from "./alertSinkAudit.mjs";
import { auditCloudVmProviderCoherence } from "./defaultProviderAudit.mjs";
import { auditFreeProvisioningOverride } from "./freeProvisioningAudit.mjs";
import {
  forbiddenRuntimeEnvKeys,
  legacyCloudVmEnvKeys,
  loadTargetEnvWithMetadata,
  mergeVercelSensitiveMetadata,
  parseBoolean,
  parseWebDirAndTarget,
  recommendedRuntimeEnvKeys,
  requiredRuntimeEnvKeySatisfied,
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
  const { env: pulledEnv, metadata } = loadTargetEnvWithMetadata(project);
  // Vercel CLI 50 writes Sensitive variables as empty strings. The metadata
  // endpoint still proves that the key exists, so represent that fact with a
  // non-secret marker for the pure audits below. This never enters a runtime
  // client because only this audit path uses the merged object.
  const env = mergeVercelSensitiveMetadata(pulledEnv, metadata);
  const keys = Object.keys(env).sort();
  const sensitiveKeys = metadata
    .filter((entry) => entry?.type === "sensitive" && typeof entry.key === "string")
    .map((entry) => entry.key)
    .sort();
  const present = new Set(
    Object.entries(env)
      .filter(([, value]) => typeof value === "string" && value.trim() !== "")
      .map(([key]) => key),
  );
  const configuredKeys = new Set(keys);
  // The Slack sink is required unless the env carries a recorded operator
  // decision to run without one; a misused acknowledgement is itself a problem.
  const alertSink = auditAlertSink(env);
  const waived = new Set(alertSink.waivedRequiredKeys);
  const missingRequired = requiredRuntimeEnvKeys.filter(
    (key) => !requiredRuntimeEnvKeySatisfied(key, present) && !waived.has(key),
  );
  const missingRecommended = recommendedRuntimeEnvKeys.filter((key) => !present.has(key));
  const forbiddenPresent = forbiddenRuntimeEnvKeys.filter((key) => configuredKeys.has(key));
  const legacyCloudVmPresent = legacyCloudVmEnvKeys.filter((key) => configuredKeys.has(key));

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
      freeProvisioning.problems.length === 0 &&
      alertSink.problems.length === 0,
    target,
    project: project.projectName,
    envKeyCount: keys.length,
    envKeys: keys,
    sensitiveKeys,
    missingRequired,
    missingRecommended,
    forbiddenPresent,
    legacyCloudVmPresent,
    providerCoherence,
    freeProvisioning,
    alertSink,
  };

  console.log(JSON.stringify(result, null, 2));
  if (strict && !result.ok) process.exit(1);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
