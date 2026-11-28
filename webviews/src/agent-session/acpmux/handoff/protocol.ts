import { translate } from "../i18n";
import { servesOperation } from "../operations";

export const MAX_CAPSULE_BYTES_V1 = 65536;

export const HANDOFF_OPS = {
  prepare: "_acpmux/handoff_prepare",
  get: "_acpmux/handoff_get",
  draft: "_acpmux/handoff_draft",
  start: "_acpmux/handoff_start",
  discard: "_acpmux/handoff_discard",
} as const;

export type Coverage = {
  item: "transcript" | "tool_output" | "plan" | "files" | "memory" | "checkpoint" | "model";
  status: "included" | "summarized" | "omitted" | "unavailable";
  detail: string | null;
};
export type Enforcement = { policy: string; label: "native_policy"; isolation: "unverified"; detail: string | null };
export type HandoffSession = {
  sessionId: string;
  harness: string;
  cwd: string;
  coverage: Coverage[];
  enforcement: Enforcement;
};
export type Handoff = {
  handoffId: string;
  handoffKey: string;
  state: "draft" | "starting" | "started" | "discarded";
  revision: number;
  source: HandoffSession & { seq: number };
  target: HandoffSession;
  capsule: {
    text: string;
    maxBytes: number;
    context: { fromSeq: number; toSeq: number; truncated: boolean; bytes: number; totalBytes: number };
    checkpoint: { ref: string; attestedBy: "user"; attestedAt: string } | null;
    memoryRefs: string[];
  };
  promptId: string | null;
  turnId: string | null;
  createdAt: string;
  updatedAt: string;
};
export type StartReceipt = {
  handoffId: string;
  targetSessionId: string;
  promptId: string;
  turnId: string | null;
  outcome: "started" | "already_started";
};

export function supportsHandoff(initialized: unknown): boolean {
  return Object.values(HANDOFF_OPS).every((op) => servesOperation(initialized, op));
}

function object(value: unknown): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error(translate("error.invalid.continuationResponse"));
  return value as Record<string, any>;
}
function requiredText(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(translate("error.invalid.continuationResponse"));
  return value;
}
function session(value: unknown): HandoffSession {
  const item = object(value);
  const enforcement = object(item.enforcement);
  if (enforcement.label !== "native_policy" || enforcement.isolation !== "unverified" || !Array.isArray(item.coverage))
    throw new Error(translate("error.unsupported.continuationCoverage"));
  requiredText(enforcement.policy);
  if (enforcement.detail !== null && typeof enforcement.detail !== "string")
    throw new Error(translate("error.invalid.enforcementReport"));
  for (const report of item.coverage) {
    if (
      !report ||
      !["transcript", "tool_output", "plan", "files", "memory", "checkpoint", "model"].includes(report.item) ||
      !["included", "summarized", "omitted", "unavailable"].includes(report.status) ||
      (report.detail !== null && typeof report.detail !== "string")
    )
      throw new Error(translate("error.invalid.continuationCoverage"));
  }
  return {
    sessionId: requiredText(item.sessionId),
    harness: requiredText(item.harness),
    cwd: requiredText(item.cwd),
    coverage: item.coverage,
    enforcement: enforcement as Enforcement,
  };
}

/** Refuse malformed owner data before using it for selection, permission labels or startup. */
export function handoffRecord(value: unknown): Handoff {
  const record = object(value);
  const source = session(record.source);
  const target = session(record.target);
  const capsule = object(record.capsule);
  const context = object(capsule.context);
  if (
    !Number.isSafeInteger(record.revision) ||
    record.revision < 1 ||
    source.sessionId === target.sessionId ||
    source.cwd !== target.cwd ||
    source.harness === target.harness ||
    !["draft", "starting", "started", "discarded"].includes(record.state) ||
    !Number.isSafeInteger(record.source.seq) ||
    record.source.seq < 0 ||
    typeof capsule.text !== "string" ||
    capsule.maxBytes !== MAX_CAPSULE_BYTES_V1 ||
    new TextEncoder().encode(capsule.text).length > capsule.maxBytes ||
    !Array.isArray(capsule.memoryRefs) ||
    capsule.memoryRefs.some((ref: unknown) => typeof ref !== "string") ||
    typeof context.truncated !== "boolean" ||
    [context.fromSeq, context.toSeq, context.bytes, context.totalBytes].some(
      (n) => !Number.isSafeInteger(n) || n < 0,
    ) ||
    context.fromSeq > context.toSeq ||
    context.bytes > context.totalBytes
  )
    throw new Error(translate("error.invalid.continuationResponse"));
  if (capsule.checkpoint !== null) {
    const checkpoint = object(capsule.checkpoint);
    requiredText(checkpoint.ref);
    if (checkpoint.attestedBy !== "user" || typeof checkpoint.attestedAt !== "string")
      throw new Error(translate("error.invalid.checkpointAttestation"));
  }
  for (const field of ["promptId", "turnId"])
    if (record[field] !== null && typeof record[field] !== "string")
      throw new Error(translate("error.invalid.continuationResponse"));
  requiredText(record.handoffId);
  requiredText(record.handoffKey);
  requiredText(record.createdAt);
  requiredText(record.updatedAt);
  return { ...record, source: { ...source, seq: record.source.seq }, target } as Handoff;
}

export class AcpmuxRpcError extends Error {
  readonly reason?: string;
  readonly code?: unknown;
  readonly data?: unknown;
  readonly handoff?: Handoff;
  constructor(error: { code?: unknown; message?: string; data?: unknown }) {
    super(error.message ?? "acpmux request failed");
    this.code = error.code;
    this.data = error.data;
    const data = error.data && typeof error.data === "object" ? (error.data as Record<string, unknown>) : undefined;
    this.reason = typeof data?.reason === "string" ? data.reason : undefined;
    if (data?.handoff) {
      try {
        this.handoff = handoffRecord(data.handoff);
      } catch {
        /* Malformed recovery data cannot replace the review. */
      }
    }
  }
}
