import type { RunSpec } from "./spec";

const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/;
const HTTPS_REPOSITORY = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\/?$/i;
const COMMIT = /^[0-9a-f]{40}$/i;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;

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
  const workspace = `/tmp/cmux-run-${marker.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
  return [
    "set -eu",
    `rm -rf ${shellQuote(workspace)}`,
    `trap 'rm -rf ${shellQuote(workspace)}' EXIT`,
    `git init -q ${shellQuote(workspace)}`,
    `git -C ${shellQuote(workspace)} remote add origin ${shellQuote(repository)}`,
    `git -C ${shellQuote(workspace)} fetch -q --depth=1 origin ${shellQuote(commit)}`,
    `git -C ${shellQuote(workspace)} checkout -q --detach FETCH_HEAD`,
    `actual_commit=$(git -C ${shellQuote(workspace)} rev-parse HEAD)`,
    `test "$actual_commit" = ${shellQuote(commit)}`,
    `test -f ${shellQuote(`${workspace}/.cmux/setup.json`)}`,
    `actual_setup="sha256:$(sha256sum ${shellQuote(`${workspace}/.cmux/setup.json`)} | awk '{print $1}')"`,
    `test "$actual_setup" = ${shellQuote(setupDigest)}`,
    `printf 'cmux-source-verified commit=%s setup=%s\\n' "$actual_commit" "$actual_setup"`,
    `printf '%s\\n' ${shellQuote(`cmux-run:${marker}`)}`,
  ].join("\n");
}

export type SourceVerificationReceipt = {
  readonly commit: string;
  readonly setupManifestDigest: string;
};

/** Parse and re-check the guest receipt against the immutable RunSpec. */
export function parseSourceVerificationReceipt(stdout: string, spec: RunSpec): SourceVerificationReceipt {
  const match = /cmux-source-verified commit=([0-9a-f]{40}) setup=(sha256:[0-9a-f]{64})/i.exec(stdout);
  if (!match?.[1] || !match[2]) throw new SourceVerificationError("guest did not emit a source verification receipt");
  const commit = match[1].toLowerCase();
  const setupManifestDigest = match[2].toLowerCase();
  if (commit !== spec.source.commit?.toLowerCase()) throw new SourceVerificationError("guest checkout commit did not match RunSpec");
  if (setupManifestDigest !== spec.source.setupManifestDigest?.toLowerCase()) throw new SourceVerificationError("guest setup manifest digest did not match RunSpec");
  return { commit, setupManifestDigest };
}
