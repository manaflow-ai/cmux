import type { RunSpec } from "./spec";

const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/;
const HTTPS_REPOSITORY = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\/?$/i;
const COMMIT = /^[0-9a-f]{40}$/i;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;
const SETUP_SCRIPT = [
  'const fs = require("node:fs");',
  'const { spawnSync } = require("node:child_process");',
  'const manifestPath = process.argv[2];',
  'const workspace = process.argv[3];',
  'const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));',
  'if (!manifest || manifest.schema !== "cmux.setup/v1" || manifest.version !== 1 || !Array.isArray(manifest.steps) || manifest.steps.length > 32) throw new Error("invalid cmux.setup/v1 manifest");',
  'for (const [index, step] of manifest.steps.entries()) {',
  '  if (!step || typeof step !== "object" || typeof step.id !== "string" || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(step.id) || typeof step.command !== "string" || step.command.length === 0 || step.command.length > 16384) throw new Error(`invalid setup step at index ${index}`);',
  '  const timeoutMs = step.timeoutMs === undefined ? 900000 : step.timeoutMs;',
  '  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 900000) throw new Error(`invalid setup timeout at index ${index}`);',
  '  const result = spawnSync("/bin/sh", ["-lc", step.command], { cwd: workspace, stdio: "inherit", timeout: timeoutMs });',
  '  if (result.error) throw result.error;',
  '  if (result.status !== 0) throw new Error(`setup step ${step.id} exited ${result.status}`);',
  '}',
  'process.stdout.write(`cmux-setup-completed steps=${manifest.steps.length}\\n`);',
].join("\n");

export class SourceVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SourceVerificationError";
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

/** Resolve the only repository forms the guest can fetch without a secret. */
export function githubRepositoryUrl(repository: string): string {
  const trimmed = repository.trim();
  if (REPOSITORY.test(trimmed)) return `https://github.com/${trimmed.replace(/\.git$/i, "")}.git`;
  const match = HTTPS_REPOSITORY.exec(trimmed);
  if (match?.[1]) return `https://github.com/${match[1]}.git`;
  throw new SourceVerificationError("source.repository must be a GitHub owner/repository or https GitHub URL");
}

/** Validate the source fields before a provider VM is allocated. */
export function assertFreestyleSource(spec: RunSpec): void {
  if (!spec.source.repository || !spec.source.commit) {
    throw new SourceVerificationError("cloud-vm runs require source.repository and source.commit");
  }
  if (!spec.source.setupManifestDigest) {
    throw new SourceVerificationError("cloud-vm runs require source.setupManifestDigest");
  }
  githubRepositoryUrl(spec.source.repository);
}

/** Return the deterministic setup verifier/executor for a checked-out source. */
export function setupExecutionCommand(workspace: string, expectedDigest: string): string[] {
  if (!DIGEST.test(expectedDigest)) throw new SourceVerificationError("setup digest must be a sha256 digest");
  const manifest = `${workspace}/.cmux/setup.json`;
  return [
    `test -f ${workspaceShellPath(manifest)}`,
    `actual_setup="sha256:$(sha256sum ${workspaceShellPath(manifest)} | awk '{print $1}')"`,
    `test "$actual_setup" = ${shellQuote(expectedDigest.toLowerCase())}`,
    `node - ${workspaceShellPath(manifest)} ${workspaceShellPath(workspace)} <<'CMUX_SETUP'`,
    SETUP_SCRIPT,
    "CMUX_SETUP",
  ];
}

function workspaceShellPath(path: string): string {
  // Production passes the fixed shell variable "$workspace"; tests pass a
  // temporary absolute path. Neither value contains RunSpec input.
  if (path === "$workspace" || path.startsWith("$workspace/")) return `"${path}"`;
  return shellQuote(path);
}

/**
 * Build the bounded guest command used by the Freestyle adapter. The command
 * fetches the requested immutable commit, verifies HEAD, hashes the checked-in
 * .cmux/setup.json bytes, and emits a parseable receipt before the caller's
 * completion marker.
 */
export function sourceVerificationCommand(spec: RunSpec, marker: string): string {
  const source = spec.source;
  assertFreestyleSource(spec);
  // assertFreestyleSource narrows these fields for the runtime contract.
  if (!source.repository || !source.commit || !source.setupManifestDigest) throw new SourceVerificationError("cloud-vm source is incomplete");
  if (!COMMIT.test(source.commit)) throw new SourceVerificationError("source.commit must be a 40-character commit SHA");
  if (!DIGEST.test(source.setupManifestDigest)) throw new SourceVerificationError("source.setupManifestDigest must be a sha256 digest");

  const repository = githubRepositoryUrl(source.repository);
  const commit = source.commit.toLowerCase();
  const setupDigest = source.setupManifestDigest.toLowerCase();
  const setupLines = setupExecutionCommand("$workspace", setupDigest);
  return [
    "set -eu",
    "workspace=$(mktemp -d \"${HOME:-/home/cmux}/.cmux-run-XXXXXX\")",
    "cleanup=1",
    "trap 'if [ \"$cleanup\" -eq 1 ]; then rm -rf -- \"$workspace\"; fi' EXIT",
    `git init -q "$workspace"`,
    `git -C "$workspace" remote add origin ${shellQuote(repository)}`,
    `git -C "$workspace" fetch -q --depth=1 origin ${shellQuote(commit)}`,
    `git -C "$workspace" checkout -q --detach FETCH_HEAD`,
    `actual_commit=$(git -C "$workspace" rev-parse HEAD)`,
    `test "$actual_commit" = ${shellQuote(commit)}`,
    ...setupLines,
    'cd "$workspace"',
    '# CMUX_VARIANT_EXECUTION',
    'cleanup=0',
    `printf 'cmux-source-verified commit=%s setup=%s workspace=%s\\n' "$actual_commit" "$actual_setup" "$workspace"`,
    `printf '%s\\n' ${shellQuote(`cmux-run:${marker}`)}`,
  ].join("\n");
}

export type SourceVerificationReceipt = {
  readonly commit: string;
  readonly setupManifestDigest: string;
  readonly setupStepCount: number;
  readonly workspacePath: string;
};

/** Parse and re-check both source and setup execution receipts. */
export function parseSourceVerificationReceipt(stdout: string, spec: RunSpec): SourceVerificationReceipt {
  const source = /cmux-source-verified commit=([0-9a-f]{40}) setup=(sha256:[0-9a-f]{64}) workspace=(\/[^\s]+)/i.exec(stdout);
  const setup = /cmux-setup-completed steps=([0-9]{1,2})/i.exec(stdout);
  if (!source?.[1] || !source[2] || !source[3]) throw new SourceVerificationError("guest did not emit a source verification receipt");
  if (!setup?.[1]) throw new SourceVerificationError("guest did not emit a setup execution receipt");
  const commit = source[1].toLowerCase();
  const setupManifestDigest = source[2].toLowerCase();
  const setupStepCount = Number(setup[1]);
  const workspacePath = source[3];
  if (commit !== spec.source.commit?.toLowerCase()) throw new SourceVerificationError("guest checkout commit did not match RunSpec");
  if (setupManifestDigest !== spec.source.setupManifestDigest?.toLowerCase()) throw new SourceVerificationError("guest setup manifest digest did not match RunSpec");
  if (!Number.isSafeInteger(setupStepCount) || setupStepCount > 32) throw new SourceVerificationError("guest setup step count was invalid");
  if (!/^\/(?:home\/cmux|root)\/\.cmux-run-[A-Za-z0-9]+$/.test(workspacePath)) throw new SourceVerificationError("guest workspace path was outside the managed home");
  return { commit, setupManifestDigest, setupStepCount, workspacePath };
}
