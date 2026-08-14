import { readBoundedJsonObject } from "../apns/routePolicy";

export const VAULT_AGENTS = ["claude", "codex", "pi"] as const;
export type VaultAgent = typeof VAULT_AGENTS[number];

export const MAX_VAULT_BATCH_ITEMS = 25;
export const MAX_VAULT_REQUEST_BYTES = 64 * 1024;

const AGENTS = new Set<string>(VAULT_AGENTS);
const SHA256_RE = /^[a-f0-9]{64}$/;
const AGENT_SESSION_ID_RE = /^[A-Za-z0-9._:-]{1,200}$/;

export type VaultUploadItem = {
  readonly agent: VaultAgent;
  readonly agentSessionId: string;
  readonly relPath: string;
  readonly cwd: string | null;
  readonly sha256: string;
  readonly sizeBytes: number;
  readonly compressedSizeBytes: number;
};

export type ValidationResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string };

export async function readVaultJsonObject(request: Request) {
  return await readBoundedJsonObject(request, MAX_VAULT_REQUEST_BYTES);
}

export function normalizeAgent(value: unknown): ValidationResult<VaultAgent> {
  if (typeof value !== "string") return { ok: false, error: "invalid_agent" };
  const normalized = value.trim().toLowerCase();
  if (!AGENTS.has(normalized)) return { ok: false, error: "invalid_agent" };
  return { ok: true, value: normalized as VaultAgent };
}

export function normalizeSha256(value: unknown): ValidationResult<string> {
  if (typeof value !== "string") return { ok: false, error: "invalid_sha256" };
  const normalized = value.trim().toLowerCase();
  if (!SHA256_RE.test(normalized)) return { ok: false, error: "invalid_sha256" };
  return { ok: true, value: normalized };
}

export function normalizeAgentSessionId(value: unknown): ValidationResult<string> {
  if (typeof value !== "string") return { ok: false, error: "invalid_agent_session_id" };
  const normalized = value.trim();
  if (!AGENT_SESSION_ID_RE.test(normalized)) return { ok: false, error: "invalid_agent_session_id" };
  return { ok: true, value: normalized };
}

export function normalizeRelPath(value: unknown): ValidationResult<string> {
  if (typeof value !== "string") return { ok: false, error: "invalid_rel_path" };
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > 512 ||
    normalized.startsWith("/") ||
    normalized.includes("\\")
  ) {
    return { ok: false, error: "invalid_rel_path" };
  }
  const parts = normalized.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    return { ok: false, error: "invalid_rel_path" };
  }
  return { ok: true, value: normalized };
}

export function validateVaultBatch(value: unknown): ValidationResult<readonly VaultUploadItem[]> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "invalid_request" };
  }
  const items = (value as { items?: unknown }).items;
  if (!Array.isArray(items)) return { ok: false, error: "missing_items" };
  if (items.length === 0 || items.length > MAX_VAULT_BATCH_ITEMS) {
    return { ok: false, error: "invalid_batch_size" };
  }

  const parsed: VaultUploadItem[] = [];
  for (const item of items) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return { ok: false, error: "invalid_item" };
    }
    const record = item as Record<string, unknown>;
    const agent = normalizeAgent(record.agent);
    if (!agent.ok) return agent;
    const agentSessionId = normalizeAgentSessionId(record.agentSessionId);
    if (!agentSessionId.ok) return agentSessionId;
    const relPath = normalizeRelPath(record.relPath);
    if (!relPath.ok) return relPath;
    const sha256 = normalizeSha256(record.sha256);
    if (!sha256.ok) return sha256;
    const sizeBytes = safeNonNegativeInteger(record.sizeBytes);
    if (sizeBytes == null) return { ok: false, error: "invalid_size_bytes" };
    const compressedSizeBytes = safeNonNegativeInteger(record.compressedSizeBytes);
    if (compressedSizeBytes == null) return { ok: false, error: "invalid_compressed_size_bytes" };
    const cwd = typeof record.cwd === "string" && record.cwd.trim() ? record.cwd.trim().slice(0, 4096) : null;
    parsed.push({
      agent: agent.value,
      agentSessionId: agentSessionId.value,
      relPath: relPath.value,
      cwd,
      sha256: sha256.value,
      sizeBytes,
      compressedSizeBytes,
    });
  }
  return { ok: true, value: parsed };
}

function safeNonNegativeInteger(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return null;
  return value;
}
