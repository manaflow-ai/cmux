/**
 * Static job classifier (DESIGN.md section 5.6): reasons a job cannot run on
 * cmux Actions. An empty list means the job is a candidate.
 */

import { isObject, type Value } from "../expr/value.ts";
import type { Job, Step, Workflow } from "../workflow/model.ts";
import type { LabelDecision } from "./labels.ts";
import { expressionsOf, isPinned, loadLocalAction, parseUses, type RepoFiles, referencedProperties } from "./references.ts";

/** Actions that need credentials or GitHub features we do not provide. */
export const CREDENTIAL_ACTIONS: Readonly<Record<string, string>> = {
  "actions/create-github-app-token": "mints a GitHub App token from secrets",
  "actions/github-script": "calls the GitHub API with github.token",
  "actions/attest": "needs GitHub OIDC attestations",
  "actions/attest-build-provenance": "needs GitHub OIDC attestations",
  "softprops/action-gh-release": "writes GitHub releases",
  "pypa/gh-action-pypi-publish": "publishes packages",
  "rust-lang/crates-io-auth-action": "needs GitHub OIDC",
  "anthropics/claude-code-action": "needs repository write credentials",
  "manaflow-ai/cla-github-action": "writes pull request comments and statuses",
  "tailscale/github-action": "joins the tailnet with secrets",
  "useblacksmith/begin-testbox": "Blacksmith-only action",
};

const MAX_COMPOSITE_DEPTH = 5;

const wantsOidc = (permissions: Value): boolean =>
  permissions === "write-all" || (isObject(permissions) && permissions["id-token"] === "write");

const stepReasons = (steps: readonly Step[], files: RepoFiles, depth: number, reasons: Set<string>): void => {
  for (const step of steps) {
    if (step.uses === null) continue;
    const ref = parseUses(step.uses);
    if (ref.kind === "docker") {
      reasons.add("Docker container actions are not supported");
      continue;
    }
    if (ref.kind === "remote") {
      if (!isPinned(ref)) reasons.add(`action not pinned to a full commit SHA: ${step.uses}`);
      const why = CREDENTIAL_ACTIONS[`${ref.owner}/${ref.repo}`];
      if (why !== undefined) reasons.add(`${ref.owner}/${ref.repo} ${why}`);
      continue;
    }
    if (depth >= MAX_COMPOSITE_DEPTH) {
      reasons.add("composite actions nested too deeply");
      continue;
    }
    const action = loadLocalAction(files, ref.path);
    if (action === undefined) {
      reasons.add(`local action not found: ${step.uses}`);
      continue;
    }
    if (action.using === "docker") reasons.add("Docker container actions are not supported");
    if (action.using === "composite") stepReasons(action.steps, files, depth + 1, reasons);
  }
};

export const classifyJob = (
  workflow: Workflow,
  job: Job,
  label: LabelDecision | null,
  files: RepoFiles,
  availableSecrets: ReadonlySet<string>,
): string[] => {
  const reasons = new Set<string>();
  if (label?.kind === "unsupported") reasons.add(label.reason);
  if (job.container !== null) reasons.add("container jobs are not supported");
  if (job.environment !== null) reasons.add("environment-protected jobs are not supported");
  if (wantsOidc(job.permissions ?? workflow.permissions)) {
    reasons.add("GitHub OIDC (id-token: write) is not available");
  }
  stepReasons(job.steps, files, 0, reasons);
  const secrets = [...referencedProperties(expressionsOf(job.raw), "secrets")].filter(
    (name) => name.toUpperCase() !== "GITHUB_TOKEN" && !availableSecrets.has(name),
  );
  if (secrets.length > 0) reasons.add(`uses secrets cmux Actions does not hold: ${secrets.sort().join(", ")}`);
  return [...reasons];
};
