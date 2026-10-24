import { createHash } from "node:crypto";
import { isIP } from "node:net";

const FULL_COMMIT = /^[0-9a-f]{40}$/iu;
const DEPLOYMENT_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/u;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
const BRANCH = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$/u;
const SENSITIVE_QUERY_KEY = /(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|authorization)/iu;

/** The source and deployment identity that a preview URL must carry. */
export type PreviewPublicationInput = {
  readonly repository: string;
  readonly branch: string;
  /** A full 40-character Git commit. Short SHAs are not accepted as evidence. */
  readonly commit: string;
  /** Provider deployment identity, kept opaque and never used as a URL. */
  readonly deploymentId: string;
  /** The provider's HTTPS preview URL. */
  readonly url: string;
  readonly createdAt?: Date | string;
  readonly expiresAt?: Date | string | null;
};

export type PreviewPublicationRecord = {
  readonly id: string;
  /** Stable idempotency key for this source/deployment pair. */
  readonly key: string;
  readonly repository: string;
  readonly branch: string;
  readonly commit: string;
  readonly deploymentId: string;
  readonly url: string;
  readonly status: "ready";
  readonly createdAt: string;
  readonly expiresAt: string | null;
};

export type PreviewPublicationResult =
  | { readonly kind: "created"; readonly publication: PreviewPublicationRecord }
  | { readonly kind: "replayed"; readonly publication: PreviewPublicationRecord }
  | { readonly kind: "conflict"; readonly reason: "source_changed" | "url_changed" };

export class PreviewPublicationInputError extends Error {
  readonly code = "preview_publication_invalid";
}

function fail(message: string): never {
  throw new PreviewPublicationInputError(message);
}

function iso(value: Date | string | undefined, field: string): string {
  const date = value instanceof Date ? value : new Date(value ?? Date.now());
  if (Number.isNaN(date.getTime())) fail(`${field} must be an ISO date`);
  return date.toISOString();
}

function optionalIso(value: Date | string | null | undefined, field: string): string | null {
  if (value === null || value === undefined) return null;
  return iso(value, field);
}

function validateRepository(value: string): string {
  if (!REPOSITORY.test(value)) fail("repository must use the owner/name form");
  return value;
}

function validateBranch(value: string): string {
  if (!BRANCH.test(value) || value.includes("..") || value.includes("//") || value.endsWith("/") || value.endsWith(".lock")) {
    fail("branch is not a valid Git ref name");
  }
  return value;
}

function validateCommit(value: string): string {
  if (!FULL_COMMIT.test(value)) fail("commit must be a full 40-character Git SHA");
  return value.toLowerCase();
}

function privateIpv4(host: string): boolean {
  const octets = host.split(".").map(Number);
  const [first, second] = octets;
  return first === 0 || first === 10 || first === 127 || (first === 100 && second >= 64 && second <= 127) ||
    (first === 169 && second === 254) || (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) || (first === 198 && second >= 18 && second <= 19);
}

function privateIpv6(host: string): boolean {
  // Unique-local (fc00::/7), link-local (fe80::/10), multicast and
  // unspecified/loopback addresses cannot be public preview origins.
  if (host.startsWith("::ffff:")) return privatePreviewHost(host.slice("::ffff:".length));
  return /^(?:fc|fd|fe[89ab]|ff)/u.test(host) || host === "::" || host === "::1";
}

function privatePreviewHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/gu, "");
  if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal")) return true;
  const version = isIP(host);
  if (version === 6) return privateIpv6(host);
  return version === 4 && privateIpv4(host);
}

function validateUrl(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    fail("url must be an absolute HTTPS URL");
  }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || !parsed.hostname || privatePreviewHost(parsed.hostname)) {
    fail("url must be a public HTTPS URL without credentials");
  }
  for (const key of parsed.searchParams.keys()) {
    if (SENSITIVE_QUERY_KEY.test(key)) fail("url query parameters must not contain credentials");
  }
  return parsed.toString();
}

function validateDeploymentId(value: string): string {
  if (!DEPLOYMENT_ID.test(value)) fail("deploymentId must be a short opaque provider id");
  return value;
}

function sourceKey(input: Pick<PreviewPublicationInput, "repository" | "branch" | "commit" | "deploymentId">): string {
  const source = `${input.repository}\u0000${input.branch}\u0000${input.commit}\u0000${input.deploymentId}`;
  return `sha256:${createHash("sha256").update(source, "utf8").digest("hex")}`;
}

/**
 * Build the public-safe record shared by a provider adapter and cmux NEXT.
 * This is pure so a CloudDO, a Vercel webhook, or a local fixture can use the
 * same provenance rules before persisting a publication.
 */
export function makePreviewPublication(input: PreviewPublicationInput): PreviewPublicationRecord {
  const repository = validateRepository(input.repository);
  const branch = validateBranch(input.branch);
  const commit = validateCommit(input.commit);
  const deploymentId = validateDeploymentId(input.deploymentId);
  const url = validateUrl(input.url);
  const createdAt = iso(input.createdAt, "createdAt");
  const expiresAt = optionalIso(input.expiresAt, "expiresAt");
  if (expiresAt && Date.parse(expiresAt) <= Date.parse(createdAt)) fail("expiresAt must be after createdAt");
  const key = sourceKey({ repository, branch, commit, deploymentId });
  return {
    id: `preview_${key.slice("sha256:".length, "sha256:".length + 24)}`,
    key,
    repository,
    branch,
    commit,
    deploymentId,
    url,
    status: "ready",
    createdAt,
    expiresAt,
  };
}

/**
 * Idempotent publication operation. A retry of the same source/deployment and
 * URL is a replay; changing either source identity or URL is a conflict.
 */
export function publishPreviewPublication(
  existing: PreviewPublicationRecord | null,
  input: PreviewPublicationInput,
): PreviewPublicationResult {
  const publication = makePreviewPublication(input);
  if (!existing) return { kind: "created", publication };
  if (existing.key !== publication.key) return { kind: "conflict", reason: "source_changed" };
  if (existing.url !== publication.url) return { kind: "conflict", reason: "url_changed" };
  return { kind: "replayed", publication: existing };
}

/** Exact-head guard used before displaying a branch preview as evidence. */
export function previewMatchesCommit(publication: PreviewPublicationRecord, commit: string): boolean {
  return FULL_COMMIT.test(commit) && publication.commit === commit.toLowerCase();
}

export function previewExpired(publication: PreviewPublicationRecord, at: Date | string = new Date()): boolean {
  return publication.expiresAt !== null && Date.parse(publication.expiresAt) <= Date.parse(iso(at, "at"));
}
