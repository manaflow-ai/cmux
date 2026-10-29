import { createHash } from "node:crypto";

export const RUN_SPEC_SCHEMA = "cmux.run/v1" as const;

export type RunSpecVariant = {
  readonly id: string;
  readonly label: string;
  readonly instructionDigest: string;
  readonly instruction?: string;
};

export type RunSpec = {
  readonly schema: typeof RUN_SPEC_SCHEMA;
  readonly operationId: string;
  readonly source: {
    readonly repository?: string;
    readonly ref?: string;
    readonly commit?: string;
    readonly archiveDigest?: string;
    readonly setupManifestDigest?: string;
    readonly imageDigest?: string;
  };
  readonly intent: { readonly digest: string };
  readonly recipe: { readonly id: string; readonly version: number };
  readonly variants: readonly RunSpecVariant[];
  readonly workspace: {
    readonly kind: "ephemeral" | "persistent";
    readonly desiredKey?: string;
    readonly layoutDigest?: string;
  };
  readonly resources: {
    readonly maxAttempts: number;
    readonly maxConcurrent: number;
    readonly memoryClass: "small" | "standard" | "large";
    readonly cpuClass: "small" | "standard" | "large";
    readonly wallTimeoutMs: number;
    readonly retainMs: number;
    readonly spendCap?: number | null;
  };
  readonly routing: {
    readonly executionProvider: "cloud-vm";
    readonly backend: "auto" | "freestyle" | "huge-blue";
  };
  readonly capabilities: {
    readonly secretRefs: readonly string[];
    readonly networkProfile?: string;
  };
  readonly checks: readonly string[];
  readonly policy: {
    readonly mode: "fanout" | "thunderdome";
    readonly humanApprovalRequired: boolean;
    readonly evidenceKinds: readonly ("screenshot" | "recording" | "patch")[];
  };
};

export class RunSpecValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RunSpecValidationError";
  }
}

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const SAFE_ID = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/i;
const COMMIT = /^[0-9a-f]{40}$/i;

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function string(value: unknown, name: string, max = 512): string {
  if (typeof value !== "string" || value.length === 0 || value.length > max || CONTROL_CHARS.test(value)) {
    throw new RunSpecValidationError(`${name} must be a bounded string without control characters`);
  }
  return value;
}

function optionalString(value: unknown, name: string, max = 512): string | undefined {
  return value === undefined || value === null ? undefined : string(value, name, max);
}

function digest(value: unknown, name: string): string {
  const result = string(value, name, 80);
  if (!DIGEST.test(result)) throw new RunSpecValidationError(`${name} must be a sha256 digest`);
  return result.toLowerCase();
}

function integer(value: unknown, name: string, min: number, max: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new RunSpecValidationError(`${name} must be an integer between ${min} and ${max}`);
  }
  return value as number;
}

function ensureNoSecretValues(value: unknown, path = "spec"): void {
  if (Array.isArray(value)) {
    value.forEach((child, index) => ensureNoSecretValues(child, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (/(?:password|token|secret|credential|api[_-]?key|authorization|cookie|private[_-]?key)/i.test(key) && key !== "secretRefs") {
      throw new RunSpecValidationError(`${path}.${key} must be a reference, not a secret value`);
    }
    ensureNoSecretValues(child, `${path}.${key}`);
  }
}

function normalizeSource(raw: Record<string, unknown>): RunSpec["source"] {
  const repository = optionalString(raw.repository, "source.repository");
  const ref = optionalString(raw.ref, "source.ref", 256);
  const commit = optionalString(raw.commit, "source.commit", 64);
  const archiveDigest = raw.archiveDigest === undefined ? undefined : digest(raw.archiveDigest, "source.archiveDigest");
  if (!commit && !archiveDigest) throw new RunSpecValidationError("source.commit or source.archiveDigest is required");
  if (commit && !COMMIT.test(commit)) throw new RunSpecValidationError("source.commit must be a 40-character commit SHA");
  const setupManifestDigest = raw.setupManifestDigest === undefined ? undefined : digest(raw.setupManifestDigest, "source.setupManifestDigest");
  const imageDigest = raw.imageDigest === undefined ? undefined : digest(raw.imageDigest, "source.imageDigest");
  return {
    ...(repository ? { repository } : {}),
    ...(ref ? { ref } : {}),
    ...(commit ? { commit: commit.toLowerCase() } : {}),
    ...(archiveDigest ? { archiveDigest } : {}),
    ...(setupManifestDigest ? { setupManifestDigest } : {}),
    ...(imageDigest ? { imageDigest } : {}),
  };
}

function instructionText(value: unknown, expectedDigest: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.length < 1 || Buffer.byteLength(value) > 16_000 || value.includes("\0")) throw new RunSpecValidationError("variant instruction must contain 1-16000 bytes without NUL");
  const actual = `sha256:${createHash("sha256").update(value).digest("hex")}`;
  if (actual !== expectedDigest) throw new RunSpecValidationError("variant instructionDigest does not match instruction");
  return value;
}

function normalizeVariants(value: unknown): RunSpecVariant[] {
  const values = Array.isArray(value) ? value : [];
  const normalized = values.map((item, index) => {
    const variant = record(item);
    const id = string(variant.id, `variants[${index}].id`, 64).toLowerCase();
    if (!SAFE_ID.test(id)) throw new RunSpecValidationError(`variants[${index}].id is invalid`);
    const instructionDigest = digest(variant.instructionDigest, `variants[${index}].instructionDigest`);
    const instruction = instructionText(variant.instruction, instructionDigest);
    return { id, label: string(variant.label, `variants[${index}].label`, 120), instructionDigest, ...(instruction === undefined ? {} : { instruction }) };
  });
  if (!normalized.length) throw new RunSpecValidationError("at least one variant is required");
  if (new Set(normalized.map(({ id }) => id)).size !== normalized.length) throw new RunSpecValidationError("variant ids must be unique");
  return normalized;
}

function normalizeResources(raw: Record<string, unknown>, variantCount: number): RunSpec["resources"] {
  const maxAttempts = integer(raw.maxAttempts ?? variantCount, "resources.maxAttempts", 1, 32);
  const maxConcurrent = integer(raw.maxConcurrent ?? Math.min(2, maxAttempts), "resources.maxConcurrent", 1, maxAttempts);
  if (maxAttempts !== variantCount) throw new RunSpecValidationError("resources.maxAttempts must equal variants.length");
  const spendCap = raw.spendCap === null || raw.spendCap === undefined ? null : raw.spendCap;
  if (spendCap !== null && (typeof spendCap !== "number" || !Number.isFinite(spendCap) || spendCap < 0)) throw new RunSpecValidationError("resources.spendCap must be a non-negative number");
  const memoryClass = raw.memoryClass === "small" || raw.memoryClass === "large" ? raw.memoryClass : "standard";
  const cpuClass = raw.cpuClass === "small" || raw.cpuClass === "large" ? raw.cpuClass : "standard";
  return { maxAttempts, maxConcurrent, memoryClass, cpuClass, wallTimeoutMs: integer(raw.wallTimeoutMs ?? 900_000, "resources.wallTimeoutMs", 1_000, 900_000), retainMs: integer(raw.retainMs ?? 600_000, "resources.retainMs", 0, 900_000), spendCap };
}

function normalizeWorkspace(raw: Record<string, unknown>): RunSpec["workspace"] {
  return { kind: raw.kind === "persistent" ? "persistent" : "ephemeral", ...(raw.desiredKey ? { desiredKey: string(raw.desiredKey, "workspace.desiredKey", 128) } : {}), ...(raw.layoutDigest ? { layoutDigest: digest(raw.layoutDigest, "workspace.layoutDigest") } : {}) };
}

function normalizeCapabilities(raw: Record<string, unknown>): RunSpec["capabilities"] {
  const secretRefs = Array.isArray(raw.secretRefs) ? raw.secretRefs.map((value, index) => string(value, `capabilities.secretRefs[${index}]`, 256)) : [];
  return { secretRefs, ...(raw.networkProfile ? { networkProfile: string(raw.networkProfile, "capabilities.networkProfile", 128) } : {}) };
}

function normalizePolicy(raw: Record<string, unknown>): RunSpec["policy"] {
  const defaultEvidenceKinds: RunSpec["policy"]["evidenceKinds"] = ["screenshot", "recording", "patch"];
  const evidenceKinds = Array.isArray(raw.evidenceKinds) ? raw.evidenceKinds.filter((value): value is RunSpec["policy"]["evidenceKinds"][number] => value === "screenshot" || value === "recording" || value === "patch") : defaultEvidenceKinds;
  return { mode: raw.mode === "fanout" ? "fanout" : "thunderdome", humanApprovalRequired: raw.humanApprovalRequired !== false, evidenceKinds };
}

/** Normalize and validate the public, secret-free RunSpec contract. */
export function normalizeRunSpec(input: unknown): RunSpec {
  ensureNoSecretValues(input);
  const raw = record(input);
  if (raw.schema !== RUN_SPEC_SCHEMA) throw new RunSpecValidationError(`schema must be ${RUN_SPEC_SCHEMA}`);
  const variants = normalizeVariants(raw.variants);
  const intent = record(raw.intent);
  const recipe = record(raw.recipe);
  const resources = normalizeResources(record(raw.resources), variants.length);
  const source = normalizeSource(record(raw.source));
  const workspace = normalizeWorkspace(record(raw.workspace));
  const routing = record(raw.routing);
  return {
    schema: RUN_SPEC_SCHEMA,
    operationId: string(raw.operationId, "operationId", 128),
    source,
    intent: { digest: digest(intent.digest, "intent.digest") },
    recipe: { id: string(recipe.id, "recipe.id", 64), version: integer(recipe.version ?? 1, "recipe.version", 1, 1000) },
    variants,
    workspace,
    resources,
    routing: { executionProvider: "cloud-vm", backend: routing.backend === "freestyle" || routing.backend === "huge-blue" ? routing.backend : "auto" },
    capabilities: normalizeCapabilities(record(raw.capabilities)),
    checks: Array.isArray(raw.checks) ? raw.checks.map((value, index) => string(value, `checks[${index}]`, 128)) : [],
    policy: normalizePolicy(record(raw.policy)),
  };
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (!value || typeof value !== "object") return JSON.stringify(value);
  return `{${Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${canonical((value as Record<string, unknown>)[key])}`).join(",")}}`;
}

export function canonicalRunSpec(spec: RunSpec): string {
  return canonical(spec);
}

export function runSpecDigest(spec: RunSpec): string {
  return `sha256:${createHash("sha256").update(canonicalRunSpec(spec), "utf8").digest("hex")}`;
}

/** Public dogfood output: references and digests remain, secret values cannot be introduced. */
export function redactedRunSpec(spec: RunSpec): RunSpec {
  return JSON.parse(canonicalRunSpec(spec)) as RunSpec;
}
