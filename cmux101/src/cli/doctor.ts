/**
 * cmux101 doctor — health-check subcommand.
 *
 * Runs a series of checks and returns a DoctorReport. Prints human-readable
 * output by default; callers may also request JSON via --output-format json.
 */

import { homedir } from "node:os";
import { join } from "node:path";
import { mkdir, writeFile, unlink } from "node:fs/promises";
import { cmuxAvailable } from "../tools/cmux/index.ts";
import { createDefaultRegistry } from "../providers/index.ts";
import { createDefaultToolRegistry } from "../tools/index.ts";
import { loadClaudeOAuth, loadCodexOAuth } from "./oauth.ts";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export interface DoctorCheck {
  name: string;
  status: "pass" | "warn" | "fail";
  message: string;
}

export interface DoctorReport {
  checks: DoctorCheck[];
  ok: boolean;
}

// ---------------------------------------------------------------------------
// Individual checks
// ---------------------------------------------------------------------------

async function checkBunVersion(): Promise<DoctorCheck> {
  const name = "bun version";
  try {
    const version: string = typeof Bun !== "undefined" ? Bun.version : "unknown";
    if (version === "unknown") {
      return { name, status: "warn", message: "Could not determine Bun version" };
    }
    const [major, minor] = version.split(".").map(Number);
    if (!isNaN(major!) && !isNaN(minor!) && (major! > 1 || (major === 1 && minor! >= 2))) {
      return { name, status: "pass", message: `Bun ${version} (>= 1.2)` };
    }
    return { name, status: "warn", message: `Bun ${version} is older than 1.2 — upgrade recommended` };
  } catch (err) {
    return { name, status: "warn", message: `Could not check Bun version: ${(err as Error).message}` };
  }
}

async function checkCmuxAvailability(): Promise<DoctorCheck> {
  const name = "cmux availability";
  try {
    const available = await cmuxAvailable();
    if (available) {
      return { name, status: "pass", message: "cmux is installed and reachable" };
    }
    return { name, status: "warn", message: "cmux not found — cmux integration is optional" };
  } catch (err) {
    return { name, status: "warn", message: `cmux check failed: ${(err as Error).message}` };
  }
}

async function checkProviderConfigured(): Promise<DoctorCheck> {
  const name = "provider configured";
  try {
    const registry = await createDefaultRegistry();
    await registry.loadFromEnv(process.env);
    const providers = registry.list();
    if (providers.length > 0) {
      const ids = providers.map((p) => p.id).join(", ");
      return { name, status: "pass", message: `${providers.length} provider(s) configured: ${ids}` };
    }
    return {
      name,
      status: "fail",
      message: "No providers configured — set an API key env var or run `cmux101 auth login <provider>`",
    };
  } catch (err) {
    return { name, status: "fail", message: `Provider check failed: ${(err as Error).message}` };
  }
}

async function checkHomeDirWritable(): Promise<DoctorCheck> {
  const name = "home dir writable";
  const probeDir = join(homedir(), ".cmux101");
  const probePath = join(probeDir, ".doctor-probe");
  try {
    await mkdir(probeDir, { recursive: true });
    await writeFile(probePath, "probe");
    await unlink(probePath);
    return { name, status: "pass", message: `~/.cmux101 is writable` };
  } catch (err) {
    return { name, status: "fail", message: `Cannot write to ~/.cmux101: ${(err as Error).message}` };
  }
}

async function checkClaudeMd(): Promise<DoctorCheck> {
  const name = "~/.cmux101/CLAUDE.md exists";
  const claudeMdPath = join(homedir(), ".cmux101", "CLAUDE.md");
  try {
    const file = Bun.file(claudeMdPath);
    const exists = await file.exists();
    if (exists) {
      return { name, status: "pass", message: "~/.cmux101/CLAUDE.md found" };
    }
    return { name, status: "warn", message: "~/.cmux101/CLAUDE.md not found (optional — create to customize system prompt)" };
  } catch {
    return { name, status: "warn", message: "~/.cmux101/CLAUDE.md not found (optional)" };
  }
}

async function checkDefaultToolsRegister(): Promise<DoctorCheck> {
  const name = "default tools register";
  try {
    const registry = await createDefaultToolRegistry();
    const tools = registry.list();
    if (tools.length > 0) {
      return { name, status: "pass", message: `${tools.length} built-in tools registered` };
    }
    return { name, status: "fail", message: "No built-in tools could be registered" };
  } catch (err) {
    return { name, status: "fail", message: `Tool registry failed: ${(err as Error).message}` };
  }
}

async function checkModelResolution(): Promise<DoctorCheck> {
  const name = "model resolution";
  try {
    const registry = await createDefaultRegistry();
    await registry.loadFromEnv(process.env);
    const providers = registry.list();
    if (providers.length === 0) {
      return { name, status: "warn", message: "No providers configured — skipping model resolution" };
    }
    const provider = providers[0]!;
    const models = await provider.listModels();
    if (models.length > 0) {
      return { name, status: "pass", message: `${provider.id} returned ${models.length} model(s)` };
    }
    return { name, status: "warn", message: `${provider.id} returned 0 models` };
  } catch (err) {
    return { name, status: "warn", message: `Model resolution failed: ${(err as Error).message}` };
  }
}

async function checkOAuthDiscovery(): Promise<DoctorCheck> {
  const name = "OAuth discovery";
  try {
    const claude = loadClaudeOAuth();
    const codex = loadCodexOAuth();
    const found: string[] = [];
    if (claude) found.push("Claude Code OAuth");
    if (codex) found.push("Codex OAuth");
    if (found.length > 0) {
      return { name, status: "pass", message: `Found: ${found.join(", ")}` };
    }
    return { name, status: "warn", message: "No external OAuth credentials discovered (Claude Code, Codex)" };
  } catch (err) {
    return { name, status: "warn", message: `OAuth discovery failed: ${(err as Error).message}` };
  }
}

// ---------------------------------------------------------------------------
// Main runner
// ---------------------------------------------------------------------------

export async function runDoctor(opts: { cwd: string; verbose?: boolean }): Promise<DoctorReport> {
  const checks = await Promise.all([
    checkBunVersion(),
    checkCmuxAvailability(),
    checkProviderConfigured(),
    checkHomeDirWritable(),
    checkClaudeMd(),
    checkDefaultToolsRegister(),
    checkModelResolution(),
    checkOAuthDiscovery(),
  ]);

  const ok = checks.every((c) => c.status !== "fail");
  return { checks, ok };
}

// ---------------------------------------------------------------------------
// Human-readable text renderer
// ---------------------------------------------------------------------------

export function renderDoctorReport(report: DoctorReport): string {
  const lines: string[] = [];
  for (const check of report.checks) {
    const badge =
      check.status === "pass" ? "[PASS]" : check.status === "warn" ? "[WARN]" : "[FAIL]";
    lines.push(`${badge} ${check.name}: ${check.message}`);
  }
  const failCount = report.checks.filter((c) => c.status === "fail").length;
  if (report.ok) {
    lines.push("\nDoctor: OK");
  } else {
    lines.push(`\nDoctor: ${failCount} issue${failCount !== 1 ? "s" : ""} found.`);
  }
  return lines.join("\n");
}
