import { sha256Hex } from "./crypto";
import { ApiError, badRequest } from "./errors";

// Computer Use approvals (PROTOCOL.md, Computer Use approvals): the request a
// machine's Computer Use worker asks about, its canonical JSON and digest, and
// the string a deciding device signs. The hub stores and forwards; the asking
// machine checks the decider's signature itself.

export type ApprovalDecision = "once" | "session" | "always" | "deny";
export const APPROVAL_DECISIONS: readonly ApprovalDecision[] = ["once", "session", "always", "deny"];
export type ApprovalState = "pending" | "decided" | "expired" | "cancelled";

/** How far ahead `answerable_until_ms` may be (the contract uses 10 min). */
export const MAX_ANSWERABLE_MS = 15 * 60 * 1000;
/** How long a closed approval stays readable after its deadline; the audit keeps it after that. */
export const APPROVAL_RETENTION_MS = 60 * 60 * 1000;
/** The largest canonical request (bytes). */
export const MAX_REQUEST_BYTES = 4096;
/** Clock skew allowed on `created_ms`. */
const CREATED_SKEW_MS = 60_000;

const NONCE = /^[0-9a-f]{32}$/;
const DIGEST = /^[0-9a-f]{64}$/;

/**
 * Canonical JSON: keys (ASCII only) sorted by code point, no whitespace,
 * integers only, strings escaped only for `"`, `\`, \b \f \n \r \t and other
 * U+0000-U+001F as \u00xx. `JSON.stringify` of a well-formed string escapes
 * exactly that set. A lone surrogate (`"\ud800"` in the body) is refused: Swift
 * and Rust clients cannot hold one, so their digests would differ.
 */
export function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw badRequest("request numbers must be integers");
    return String(value);
  }
  if (typeof value === "string") {
    if (!(value as string & { isWellFormed(): boolean }).isWellFormed()) throw badRequest("request strings must be valid Unicode");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj);
    for (const k of keys) {
      if (!/^[\x20-\x7e]+$/.test(k)) throw badRequest("request keys must be printable ASCII");
    }
    keys.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`).join(",")}}`;
  }
  throw badRequest("request holds a value JSON cannot carry");
}

/** The lowercase hex SHA-256 of the canonical JSON of `request` without `digest`. */
export async function requestDigest(request: Record<string, unknown>): Promise<string> {
  const { digest: _omit, ...rest } = request;
  return sha256Hex(canonicalJson(rest));
}

/** The string a deciding device signs. */
export function decisionMessage(digest: string, decision: ApprovalDecision): string {
  return `cmux-cu-approval-v1\n${digest}\n${decision}`;
}

function text(v: unknown, field: string, max = 200): string {
  if (typeof v !== "string" || v.length === 0 || v.length > max) throw badRequest(`${field} must be a string of 1-${max} characters`);
  return v;
}

function integer(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0) throw badRequest(`${field} must be a non-negative integer`);
  return v;
}

export interface ValidRequest {
  request: Record<string, unknown>;
  nonce: string;
  digest: string;
  answerableUntil: number;
  agent: string;
  workspace: string;
  tool: string;
  targetName: string;
}

/**
 * Checks the worker's request object (docs/computer-use-approvals.md, The
 * approval question) and that its `digest` is the one its fields give.
 * Unknown fields are kept: they are part of the digest.
 */
export async function validateRequest(input: unknown, now: number): Promise<ValidRequest> {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw badRequest("request must be an object");
  const r = input as Record<string, unknown>;
  if (r.v !== 1) throw badRequest("request.v must be 1");
  if (typeof r.nonce !== "string" || !NONCE.test(r.nonce)) throw badRequest("request.nonce must be 32 lowercase hex digits");
  if (typeof r.digest !== "string" || !DIGEST.test(r.digest)) throw badRequest("request.digest must be 64 lowercase hex digits");
  for (const f of ["client", "machine", "session", "agent", "workspace", "tool", "risk"]) text(r[f], `request.${f}`);
  const target = r.target;
  if (!target || typeof target !== "object" || Array.isArray(target)) throw badRequest("request.target must be an object");
  const t = target as Record<string, unknown>;
  for (const f of ["bundle_id", "executable"]) {
    if (t[f] !== null && t[f] !== undefined) text(t[f], `request.target.${f}`, 1024);
  }
  if ((t.bundle_id ?? null) === null && (t.executable ?? null) === null) throw badRequest("request.target needs a bundle_id or an executable");
  const targetName = text(t.name, "request.target.name");
  const created = integer(r.created_ms, "request.created_ms");
  const waitUntil = integer(r.wait_until_ms, "request.wait_until_ms");
  const answerableUntil = integer(r.answerable_until_ms, "request.answerable_until_ms");
  if (!(created <= waitUntil && waitUntil <= answerableUntil)) throw badRequest("request times must satisfy created_ms <= wait_until_ms <= answerable_until_ms");
  if (created > now + CREATED_SKEW_MS) throw badRequest("request.created_ms is in the future");
  if (answerableUntil <= now) throw badRequest("request.answerable_until_ms is in the past");
  if (answerableUntil > now + MAX_ANSWERABLE_MS) throw badRequest("request.answerable_until_ms is more than 15 minutes away");
  const { digest: _omit, ...rest } = r;
  const canonical = canonicalJson(rest);
  if (new TextEncoder().encode(canonical).length > MAX_REQUEST_BYTES) throw badRequest("request is larger than 4 KiB");
  const digest = await sha256Hex(canonical);
  if (digest !== r.digest) throw new ApiError(400, "digest_mismatch", "request.digest is not the SHA-256 of its canonical JSON");
  return {
    request: r,
    nonce: r.nonce,
    digest,
    answerableUntil,
    agent: r.agent as string,
    workspace: r.workspace as string,
    tool: r.tool as string,
    targetName,
  };
}

// ---- display text for the phone push ----

/** Printable text cut to `max` code points: control and format characters become spaces (as the mobile Worker does). */
export function clean(value: string, max: number): string {
  const chars = Array.from(
    value
      .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/gu, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/(\p{Mn}{2})\p{Mn}+/gu, "$1"),
  );
  return chars.length <= max ? chars.join("") : `${chars.slice(0, Math.max(0, max - 1)).join("")}…`;
}
