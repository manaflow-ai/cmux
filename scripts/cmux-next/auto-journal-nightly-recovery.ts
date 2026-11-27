#!/usr/bin/env bun
/**
 * RFD 0080: recovery boundary proof against a published cmux-tui NIGHTLY.
 *
 * This driver deliberately stops at the supported integration boundary.  The Auto store's
 * takeover API accepts only an owner install or a Cloud-machine install; a Stack bearer
 * (even one made by --fresh-account) is not a laptop caller.  Until the published-daemon
 * install/socket harness is made a shared export, this command records that blocker rather
 * than guessing an install endpoint or claiming a recovery result.
 *
 * The pure checks below are used by the eventual run and are intentionally useful now:
 * provenance is pinned, the real Claude login is validated without printing it, the store
 * wait uses the documented `/wait` route, and freeze/cleanup can target only a detached
 * process group this driver started.
 *
 *   bun scripts/cmux-next/auto-journal-nightly-recovery.ts \
 *     --cmux-tui /path/to/published/cmux-tui --provenance nightly.json --out DIR
 */
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import type { ChildProcess } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { http, resolveBackend, validLogin, type Api } from "./cloud-journey.ts";

export type NightlyProvenance = {
  source_sha: string;
  workflow_run: string | number;
  artifact_sha256: string;
  published: true;
  app_build?: string;
  feed_url?: string;
};

export type RecoveryEvidence = {
  status: "preflight" | "blocked" | "pass" | "fail";
  blocker?: string;
  source_sha?: string;
  workflow_run?: string;
  artifact_sha256?: string;
  account_email?: string;
  wait_route?: string;
  checks: Record<string, "pass" | "fail" | "blocked">;
};

const value = (name: string, argv = process.argv): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

/** Reject moving refs and require the immutable publication receipt fields. */
export function validateProvenance(value: unknown): NightlyProvenance {
  if (!value || typeof value !== "object") throw new Error("provenance must be a JSON object");
  const p = value as Record<string, unknown>;
  if (!/^[0-9a-f]{40}$/.test(String(p.source_sha ?? ""))) throw new Error("provenance.source_sha must be a full 40-hex commit");
  if (!(typeof p.workflow_run === "string" || (typeof p.workflow_run === "number" && Number.isSafeInteger(p.workflow_run)))) throw new Error("provenance.workflow_run is required");
  if (!/^[0-9a-f]{64}$/.test(String(p.artifact_sha256 ?? ""))) throw new Error("provenance.artifact_sha256 must be sha256");
  if (p.published !== true) throw new Error("provenance.published must be true for a shipped NIGHTLY");
  return {
    source_sha: String(p.source_sha),
    workflow_run: p.workflow_run as string | number,
    artifact_sha256: String(p.artifact_sha256),
    published: true,
    ...(typeof p.app_build === "string" ? { app_build: p.app_build } : {}),
    ...(typeof p.feed_url === "string" ? { feed_url: p.feed_url } : {}),
  };
}

/** No token reaches reports, logs, or error details. */
export function claudeLoginFromEnv(env: Record<string, string | undefined> = process.env): string {
  const token = (env.CLAUDE_CODE_OAUTH_TOKEN ?? "").trim();
  if (!token || !validLogin("claude", token)) throw new Error("CLAUDE_CODE_OAUTH_TOKEN is unset or is not a `claude setup-token` login");
  return token;
}

/** The documented store wait; callers pass the last observed `version`. */
export async function waitStore(api: Pick<Api, "origin" | "bearer">, id: string, after: number, timeoutMs = 25_000) {
  const bounded = Math.max(0, Math.min(timeoutMs, 25_000));
  return http("GET", `${api.origin}/v1/auto-sessions/${encodeURIComponent(id)}/wait?after=${encodeURIComponent(String(after))}&timeoutMs=${bounded}`, undefined, { authorization: `Bearer ${api.bearer}` }, bounded + 5_000);
}

/** Freeze only a detached process group owned by this run; never accepts an arbitrary pid. */
export function freezeOwned(child: Pick<ChildProcess, "pid" | "exitCode" | "spawnargs">): () => void {
  const pid = child.pid;
  if (!pid || child.exitCode !== null || !child.spawnargs?.length) throw new Error("cannot freeze an unstarted or non-owned process");
  process.kill(-pid, "SIGSTOP");
  let thawed = false;
  return () => {
    if (thawed) return;
    thawed = true;
    try { process.kill(-pid, "SIGCONT"); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ESRCH") throw e; }
  };
}

/** Journal evidence is accepted only when every record has the native holder prefix. */
export function assertJournalPrefix(records: readonly string[], prefix: string): void {
  if (!prefix || records.length === 0) throw new Error("journal prefix evidence is empty");
  if (records.some((line) => !line.startsWith(prefix))) throw new Error("journal contains a record without the native holder prefix");
}

/** A recovery proof must show the old holder was fenced, never replayed through a shell. */
export function assertNoShellReplay(records: readonly string[]): void {
  if (records.some((line) => /(?:sh|bash|zsh)\s+-c|shell replay|replayed command/i.test(line))) throw new Error("journal contains shell replay evidence");
}

async function main(): Promise<number> {
  const binary = path.resolve(value("--cmux-tui") ?? "");
  const provenancePath = path.resolve(value("--provenance") ?? "");
  const out = path.resolve(value("--out") ?? "auto-journal-nightly-recovery-out");
  mkdirSync(out, { recursive: true });
  const checks: RecoveryEvidence["checks"] = {};
  const evidence: RecoveryEvidence = { status: "preflight", checks };
  try {
    if (!binary || !existsSync(binary) || !statSync(binary).isFile()) throw new Error("--cmux-tui must name the published cmux-tui binary");
    checks.binary = "pass";
    const provenance = validateProvenance(JSON.parse(readFileSync(provenancePath, "utf8")));
    checks.provenance = "pass";
    evidence.source_sha = provenance.source_sha;
    evidence.workflow_run = String(provenance.workflow_run);
    evidence.artifact_sha256 = provenance.artifact_sha256;
    const token = claudeLoginFromEnv();
    // Keep the secret live only for validation; never put it in evidence or child env here.
    void token;
    checks.claude_login = "pass";
    const backend = resolveBackend(value("--backend") ?? "staging");
    if (backend.name !== "staging") throw new Error(`recovery driver requires staging (got ${backend.name})`);
    checks.backend = "pass";
    evidence.wait_route = `${backend.api}/v1/auto-sessions/:id/wait`;
    evidence.status = "blocked";
    evidence.blocker = "published-daemon install/socket harness is not a supported shared export: Auto lease/takeover routes require an owner or machine install; a Stack bearer/fresh account cannot create the laptop holder (routes.ts open/lease, noLaptop). Reuse auto-journey's install/socket harness before executing recovery.";
    checks.install_harness = "blocked";
    writeFileSync(path.join(out, "evidence.json"), `${JSON.stringify(evidence, null, 2)}\n`);
    console.error(evidence.blocker);
    return 2;
  } catch (error) {
    evidence.status = "fail";
    evidence.blocker = String((error as Error)?.message ?? error).replace(/sk-ant-oat01-[\x21-\x7e]+/g, "[redacted]");
    writeFileSync(path.join(out, "evidence.json"), `${JSON.stringify(evidence, null, 2)}\n`);
    console.error(evidence.blocker);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(await main());
