import { createHash } from "node:crypto";
import { sandboxHourUsd, SANDBOX_LIST_USD } from "../billing/chiefPricing";
import { findVmImageManifestEntry } from "../vms/images/resolver";
import type { ProviderId } from "../vms/drivers";
import { isDeployedRuntime, type VmRuntimeEnv } from "../vms/config";
import type { RunSnapshotRow } from "./view";
import { isArtifactDigest, type RunStatus, type SandboxRunOutcome, type SandboxRunReceipt } from "./model";

/** Characters of terminal output a receipt keeps (redacted); a sandbox journals no raw output. */
export const SANDBOX_REPLY_MAX_CHARS = 4_000;

const ANSI = /\u001b\[[0-?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)|\u001b[@-Z\\-_]/g;

/** `text` without terminal escapes and other control characters (newlines and tabs kept). */
export function stripTerminalEscapes(text: string): string {
  // A carriage return (progress output rewriting its line) is a line break here: dropping it would
  // join the next text to the last, and a token after it would lose the boundary it is found by.
  return text.replace(ANSI, "").replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "");
}
/**
 * The names that make a key's value a secret, shared by every pattern below (a key, a header,
 * a label at the end of a line, a YAML block scalar): one grammar, so no form is missed by one
 * pattern that another catches.
 */
const SECRET_NAME = String.raw`(?:token|password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|account[_-]?key|private[_-]?key|authorization|credential|shared[_-]?access[_-]?signature|key[_-]?data|signature|cookie)`;

/** Token shapes an agent may echo; the receipt is shared wider than the terminal. */
// Token prefixes match after any non-alphanumeric (`_`, `-`, `/`), not only a word boundary:
// `\b` never matches after `_`, so `dump_sk-…` would slip through.
const TOKEN_SHAPES = [
  // The provider-secret shapes of services/sentry.ts, plus common package-registry and SaaS tokens.
  /(?<![A-Za-z0-9])(?:sk|srt|pk|rk|sk_live|sk_test|rk_live|rk_test|whsec)[-_][A-Za-z0-9_-]{8,}/g,
  /(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}/g,
  /(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}/g,
  /(?<![A-Za-z0-9])gl(?:pat|dt|rt|ptt|cbt|oas|soat|ffct|imt|agent)-[A-Za-z0-9_-]{16,}/g,
  // Common prefixed API tokens (Sentry, Docker, PyPI, Shopify, Linear, Figma, DigitalOcean, Vercel,
  // npm, RubyGems, Postman, Databricks, HashiCorp, Doppler, Grafana, SendGrid, Twilio, Mailgun).
  /(?<![A-Za-z0-9])(?:sntry[su]_|dckr_pat_|dckr_oat_|pypi-|shp(?:at|ss|ca|pa)_|lin_(?:api|oauth)_|figd_|do[opr]_v1_|vcp_|npm_|rubygems_|PMAK-|hvs\.|hvb\.|dp\.(?:pt|st|sa|ct)\.|glsa_|glc_|SG\.)[A-Za-z0-9._=-]{16,}/g,
  // Bare-prefix API keys a coding agent is likely to print (Resend, Groq, xAI, Perplexity,
  // Replicate, Tavily, Fireworks, Google OAuth access tokens, Supabase, LangSmith, Netlify,
  // Atlassian, Cloudflare, Fly.io, Railway-style UUID-free tokens).
  /(?<![A-Za-z0-9])(?:re_|gsk_|xai-|pplx-|r8_|tvly-|fw_|ya29\.|sbp_|sb_secret_|lsv2_(?:pt|sk)_|nfp_|ATATT|cfut_|fo1_)[A-Za-z0-9_-]{20,}/g,
  // Fixed-length hex tokens whose prefix alone is ordinary text (Databricks, Twilio, Mailgun).
  /(?<![A-Za-z0-9])(?:dapi[0-9a-f]{32}|SK[0-9a-f]{32}|key-[0-9a-f]{32})(?![A-Za-z0-9])/g,
  /(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}/g,
  /(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}/g,
  /(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{30,}/g,
  /(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}/g,
  /(?<![A-Za-z0-9])xapp-[A-Za-z0-9-]{10,}/g,
  /(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])/g,
  // Credentials inside a URL (`postgres://user:pass@host`) and Basic auth.
  /((?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9+.-]*:\/\/)[^/?#\s@]+@/g,
  /((?<![A-Za-z0-9])basic\s+)[A-Za-z0-9+/]{4,}=*/gi,
  /(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g,
  /((?<![A-Za-z0-9])bearer\s+)[A-Za-z0-9._~+/-]{8,}=*/gi,
  // Credentials in query strings and connection strings: Azure SAS `sig=`, `AccountKey=`,
  // `SharedAccessKey=`, `SharedAccessSignature=`, and npm's `_auth=`.
  /(\b(?:sig|AccountKey|SharedAccessKey|SharedAccessSignature|_auth)=)[^&\s;"',]+/gi,
  // npm's `_auth`, Azure SAS `sig`, and the signature and credential parameters of signed cloud URLs
  // (`X-Amz-Signature`, `X-Goog-Signature`, …), in any spacing, quoting or JSON; the key exactly
  // (`my_author` and `signal` are not one).
  // Docker's config.json `"auth": "<base64 user:password>"` (the quoted JSON key only: a bare `auth:` is ordinary text).
  /((?<![A-Za-z0-9_-])"auth"\s*:\s*)(?:"(?:[^"\\]|\\.)*(?:"|$))/gi,
  /((?<![A-Za-z0-9_-])(?:_auth|sig|x-(?:amz|goog)-(?:signature|credential|security-token))["']?\s*[:=]\s*)(?:"(?:[^"\\]|\\.)*(?:"|$)|'(?:[^'\\]|\\.)*(?:'|$)|[^\s"',;}]+)/gi,
  // `PASSWORD="…"`, `api_key: …`, `"clientSecret": "…"`, `MY_TOKEN=…`: a secret-named key, then its
  // value; a quoted value the output cut off before its closing quote runs to the end.
  new RegExp(String.raw`(\b[A-Za-z0-9_-]*${SECRET_NAME}[A-Za-z0-9_-]*["']?\s*[:=]\s*)(?:"(?:[^"\\]|\\.)*(?:"|$)|'(?:[^'\\]|\\.)*(?:'|$)|[^\s"',;}]+)`, "gi"),
  // A cookie header carries its secrets as `name=value` pairs: every value goes, whatever its name.
  /((?:^|\n)[ \t]*(?:set-)?cookie[ \t]*:[ \t]*)[^\n]*/gi,
];

/**
 * A YAML block scalar under a secret-named key (`password: |-` then its indented lines): the
 * indented lines are the value.
 */
const YAML_SECRET_HEADER = String.raw`["']?[A-Za-z0-9_-]*${SECRET_NAME}[A-Za-z0-9_-]*["']?[ \t]*:[ \t]*[|>][-+0-9]*[ \t]*(?:#[^\n]*)?`;
const YAML_SECRET_BLOCK = new RegExp(String.raw`((?:^|\n)([ \t]*)${YAML_SECRET_HEADER}\n)((?:\2[ \t]+[^\n]*(?:\n|$)|[ \t]*\n)+)`, "gi");
const YAML_SECRET_HEADER_LINE = new RegExp(String.raw`^[ \t]*${YAML_SECRET_HEADER}$`, "i");

/** Whether `line` (no newline) opens a YAML block scalar under a secret key, as the redactor reads one. */
export function isYamlSecretHeader(line: string): boolean {
  return YAML_SECRET_HEADER_LINE.test(line);
}

/** A PEM or OpenSSH private key block, whole (the receipt never needs one). */
const PRIVATE_KEY_BLOCK = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|$)/g;

/**
 * Remove terminal escapes, token-shaped strings and the given exact values (provider handles)
 * from text a receipt shows. Runs where the text is stored and again where it is served.
 */
export function redactReceiptText(text: string, exact: readonly (string | null | undefined)[] = []): string {
  let out = stripTerminalEscapes(text)
    .replace(PRIVATE_KEY_BLOCK, "[redacted private key]")
    .replace(YAML_SECRET_BLOCK, (_match, head: string, indent: string) => `${head}${indent}  [redacted]\n`);
  for (const value of exact) {
    if (value) out = out.split(value).join("[redacted]");
  }
  for (const shape of TOKEN_SHAPES) {
    out = out.replace(shape, (match, prefix: unknown) => (typeof prefix === "string" ? `${prefix}[redacted]` : "[redacted]"));
  }
  return out;
}

/** The tail of a terminal transcript, safe to show as a chat's result. */
export function sandboxReply(output: string, exact: readonly (string | null | undefined)[] = []): string | null {
  let text = redactReceiptText(output.replace(/\r\n?/g, "\n"), exact);
  text = text.trim();
  if (!text) return null;
  return text.length > SANDBOX_REPLY_MAX_CHARS ? `…${text.slice(-SANDBOX_REPLY_MAX_CHARS)}` : text;
}

function iso(value: Date | null | undefined): string | null {
  return value ? value.toISOString() : null;
}

function between(from: Date | null | undefined, to: Date | null | undefined): number | null {
  return from && to ? Math.max(0, to.getTime() - from.getTime()) : null;
}

/** A bare `type/subtype` that redaction leaves unchanged; anything else shows as octet-stream. */
function safeMediaType(value: string, handles: readonly (string | null | undefined)[]): string {
  return MEDIA_TYPE.test(value) && redactReceiptText(value, handles) === value ? value : "application/octet-stream";
}

const MEDIA_TYPE = /^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$/;

function storedOutcome(value: Record<string, unknown> | null | undefined): SandboxRunOutcome | null {
  if (!value) return null;
  const num = (key: string) => (typeof value[key] === "number" && Number.isFinite(value[key]) ? value[key] as number : null);
  return {
    reply: typeof value.reply === "string" ? value.reply : null,
    exitCode: num("exitCode"),
    signal: num("signal"),
    timedOut: value.timedOut === true,
    bootMs: num("bootMs"),
    error: typeof value.error === "string" ? value.error : null,
  };
}

const TERMINAL_RUN_STATUSES: readonly RunStatus[] = ["succeeded", "failed", "cancelled"];

/**
 * Build a sandboxed Run's receipt from its rows. The launcher's outcome (reply, exit code) is
 * merged in when it was recorded; a Run whose controller died still gets a receipt from the
 * journal alone. Cleanup is read live, so a destroy the reaper finishes later shows here.
 */
export function sandboxReceiptFor(snapshot: RunSnapshotRow, provider: ProviderId = "freestyle"): SandboxRunReceipt | null {
  const { run } = snapshot;
  if (run.environment !== "sandboxed" || !run.imageId) return null;
  const status = run.status as RunStatus;
  if (!TERMINAL_RUN_STATUSES.includes(status)) return null;
  const outcome = storedOutcome(run.receipt);
  const attempt = snapshot.attempts[0];
  // Cleanup scrubs stored text before it clears the handles; until then they are redacted here.
  const handles = snapshotHandles(snapshot);
  return {
    schema: "cmux.run.receipt/v1",
    runId: run.id,
    environment: "sandboxed",
    status,
    image: { id: run.imageId, version: run.imageVersion ?? null },
    ...receiptOutcome(outcome, attempt?.exitCode ?? null, outcome?.error ?? attempt?.error ?? run.error, handles),
    artifacts: snapshot.artifacts.map((artifact) => ({
      name: redactReceiptText(artifact.name, handles),
      // A bare `type/subtype`; parameters (`; token=…`) or anything else is not shown.
      mediaType: safeMediaType(artifact.mediaType, handles),
      sizeBytes: artifact.sizeBytes,
      digest: servedDigest(artifact.digest),
    })),
    ...receiptTimingsAndCost(snapshot, outcome, provider, run.imageId),
    cleanup: sandboxCleanupPending(snapshot) ? "pending" : "destroyed",
  };
}

function sandboxCleanupPending(snapshot: RunSnapshotRow): boolean {
  return !!snapshot.sandboxVmLive || snapshot.attempts.some((row) => row.providerVmId);
}

/** Keys whose value is a secret whatever it looks like. */
const SECRET_KEY = /(?:token|password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|account[_-]?key|private[_-]?key|authorization|credential|cookie|session|shared[_-]?access|signature|key[_-]?data|^_?auth$|^sig$|^x-(?:amz|goog)-(?:credential|security-token)$)/i;

/**
 * Every string inside `value` (any depth) redacted like the receipt: keys too, and the whole value
 * under a secret-named key.
 */
export function redactReceiptValue(value: unknown, handles: readonly (string | null | undefined)[]): unknown {
  if (typeof value === "string") return redactReceiptText(value, handles);
  if (Array.isArray(value)) return value.map((item) => redactReceiptValue(item, handles));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      redactReceiptText(key, handles),
      SECRET_KEY.test(key) && item !== null && item !== undefined ? "[redacted]" : redactReceiptValue(item, handles),
    ]));
  }
  return value;
}

/**
 * A sandboxed Run's artifact as the snapshot serves it: name, media type, URI and every string in
 * its metadata redacted like the receipt (with the attempt's handles while it still has them).
 */
/** A digest as served: a `sha256:` digest, or a placeholder for anything else a worker wrote. */
function servedDigest(digest: string): string {
  return isArtifactDigest(digest) ? digest : "[redacted]";
}

/** Every handle a sandboxed Run's text could name: its attempt's, and its VM rows' provider ids. */
function snapshotHandles(snapshot: RunSnapshotRow): (string | null | undefined)[] {
  const attempt = snapshot.attempts[0];
  return [attempt?.providerVmId, attempt?.providerWorkspaceId, attempt?.providerTerminalId, ...(snapshot.sandboxVmHandles ?? [])];
}

/** A sandboxed Run's run or attempt error as served: redacted like its receipt. */
export function sandboxErrorView(error: string | null, snapshot: RunSnapshotRow): string | null {
  return error === null ? null : redactReceiptText(error, snapshotHandles(snapshot));
}

export function sandboxArtifactView<T extends { readonly name: string; readonly mediaType: string; readonly digest: string; readonly uri: string; readonly metadata: Record<string, unknown> }>(view: T, snapshot: RunSnapshotRow): T {
  const handles = snapshotHandles(snapshot);
  return {
    ...view,
    digest: servedDigest(view.digest),
    name: redactReceiptText(view.name, handles),
    mediaType: safeMediaType(view.mediaType, handles),
    uri: redactReceiptText(view.uri, handles),
    metadata: redactReceiptValue(view.metadata, handles) as Record<string, unknown>,
  };
}

function receiptOutcome(
  outcome: SandboxRunOutcome | null,
  attemptExitCode: number | null,
  error: string | null,
  handles: readonly (string | null | undefined)[],
): Pick<SandboxRunReceipt, "exitCode" | "signal" | "timedOut" | "reply" | "error"> {
  const reply = outcome?.reply ? redactReceiptText(outcome.reply, handles).slice(-(SANDBOX_REPLY_MAX_CHARS + 1)) : null;
  return {
    exitCode: outcome?.exitCode ?? attemptExitCode,
    signal: outcome?.signal ?? null,
    timedOut: outcome?.timedOut ?? false,
    reply,
    error: error ? redactReceiptText(error, handles).slice(0, 500) : null,
  };
}

/**
 * Seconds the VM existed: each VM row created under the sandbox's key, from its creation to its
 * destruction, or to now while it is still up (the cost is then provisional). Without a VM row the
 * lifetime is unknown: the attempt's own timings say when the task ran, not when its VM went away.
 */
function vmSecondsFor(snapshot: RunSnapshotRow): number | null {
  const vms = snapshot.sandboxVms ?? [];
  // No VM row to measure (none was made, or its row is gone), or a machine nobody recorded may
  // exist: the lifetime is unknown, not zero.
  if (vms.length === 0 || snapshot.sandboxVmUnknown) return null;
  const nowMs = Date.now();
  const ms = vms.reduce((sum, vm) => sum + Math.max(0, (vm.destroyedAt?.getTime() ?? nowMs) - vm.createdAt.getTime()), 0);
  return Math.round(ms / 1000);
}

function receiptCost(provider: ProviderId, imageId: string, vmSeconds: number | null, final: boolean): SandboxRunReceipt["cost"] {
  const size = findVmImageManifestEntry(provider, imageId)?.size ?? null;
  const hourUsd = size ? sandboxHourUsd({ vcpu: size.cpu, gib: size.memoryMb / 1024 }, SANDBOX_LIST_USD) : null;
  const estimateUsd = hourUsd === null || vmSeconds === null ? null : Math.round(hourUsd * (vmSeconds / 3600) * 10_000) / 10_000;
  return { vmSeconds, vcpus: size?.cpu ?? null, memoryMb: size?.memoryMb ?? null, estimateUsd, final };
}

function receiptTimingsAndCost(
  snapshot: RunSnapshotRow,
  outcome: SandboxRunOutcome | null,
  provider: ProviderId,
  imageId: string,
): Pick<SandboxRunReceipt, "timings" | "cost"> {
  const { run } = snapshot;
  const attempt = snapshot.attempts[0];
  const finishedAt = attempt?.finishedAt ?? run.completedAt ?? null;
  return {
    timings: {
      createdAt: run.createdAt.toISOString(),
      startedAt: iso(attempt?.startedAt),
      finishedAt: iso(finishedAt),
      bootMs: outcome?.bootMs ?? null,
      runMs: between(attempt?.startedAt, finishedAt),
      totalMs: between(run.createdAt, finishedAt),
    },
    // Final once no VM is left: until then the VM time (and its cost) is still counting.
    cost: receiptCost(provider, imageId, vmSecondsFor(snapshot), !sandboxCleanupPending(snapshot)),
  };
}

/** The event payload keys whose values are provider handles: cleanup redacts them whole. */
export const SANDBOX_HANDLE_KEYS: ReadonlySet<string> = new Set(["providerVmId", "providerWorkspaceId", "providerTerminalId"]);

/**
 * The key cleanup adds to an event payload it scrubbed: the digest of the payload as the worker
 * sent it, so the worker's retry of that event is still recognized as the same event. Workers
 * may not send it; the served view drops it.
 */
export const SANDBOX_SCRUBBED_FROM_KEY = "cmux:scrubbedFrom";

/** A digest of a JSON value that ignores key order (a jsonb round trip reorders keys). */
export function sandboxPayloadDigest(value: unknown): string {
  const canonical = (item: unknown): unknown => {
    if (Array.isArray(item)) return item.map(canonical);
    if (item && typeof item === "object") {
      return Object.fromEntries(Object.keys(item).sort().map((key) => [key, canonical((item as Record<string, unknown>)[key])]));
    }
    return item;
  };
  return `sha256:${createHash("sha256").update(JSON.stringify(canonical(value ?? {}))).digest("hex")}`;
}

/** Accounts that may start sandboxed Runs: comma- or space-separated Stack user ids; empty allows nobody. */
export const RUN_SANDBOX_USERS_ENV = "CMUX_RUN_SANDBOX_USER_IDS";

/**
 * The server's per-deployment allowlist for sandboxed Runs (the app has no Labs gate). Local dev
 * allows everyone; a deployment allows only the accounts it names, `*` for all.
 */
export function sandboxRunsAllowed(userId: string, env: VmRuntimeEnv = process.env): boolean {
  if (!isDeployedRuntime(env)) return true;
  const allowed = (env[RUN_SANDBOX_USERS_ENV] ?? "").split(/[\s,]+/).filter((id) => id.length > 0);
  return allowed.includes("*") || allowed.includes(userId);
}
