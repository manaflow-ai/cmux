// Harness definitions and availability detection. A harness is available only
// if its CLI exists on this Mac and is logged in.

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { childEnv, findExecutable } from "../util.ts";

export interface HarnessSpec {
  id: string;
  name: string;
  /** ACP agent launcher. */
  command: string;
  args: string[];
  env?: Record<string, string>;
  /** Resolves true when the harness can be used right now. */
  detect: () => Promise<boolean>;
  /** Initials and tint for conversation avatars. */
  initials: string;
  tint: string;
}

function npxPath(): string {
  const local = join(dirname(process.execPath), "npx");
  return existsSync(local) ? local : (findExecutable("npx") ?? "npx");
}

function launcher(envVar: string, pkg: string): { command: string; args: string[] } {
  const override = process.env[envVar]?.trim();
  if (override) {
    const parts = override.split(/\s+/);
    return { command: parts[0]!, args: parts.slice(1) };
  }
  return { command: npxPath(), args: ["-y", pkg] };
}

function run(cmd: string, args: string[], timeoutMs = 15_000): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, env: childEnv(), maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
      const code = err ? (typeof (err as { code?: unknown }).code === "number" ? (err as { code: number }).code : 1) : 0;
      resolve({ code, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

export async function claudeLoggedIn(): Promise<boolean> {
  const bin = findExecutable("claude");
  if (!bin) return false;
  if (process.env.ANTHROPIC_API_KEY || process.env.CLAUDE_CODE_OAUTH_TOKEN) return true;
  const r = await run(bin, ["auth", "status"]);
  try {
    const parsed = JSON.parse(r.stdout);
    if (typeof parsed.loggedIn === "boolean") return parsed.loggedIn;
  } catch {}
  // Older CLIs without `auth status`: look for a stored OAuth account.
  try {
    const cfg = JSON.parse(readFileSync(join(homedir(), ".claude.json"), "utf8"));
    return Boolean(cfg.oauthAccount);
  } catch {
    return false;
  }
}

export async function codexLoggedIn(): Promise<boolean> {
  const bin = findExecutable("codex");
  if (!bin) return false;
  if (process.env.OPENAI_API_KEY || process.env.CODEX_API_KEY) return true;
  const r = await run(bin, ["login", "status"]);
  const text = `${r.stdout}\n${r.stderr}`;
  return r.code === 0 && !/not logged in/i.test(text);
}

export function defaultHarnesses(): HarnessSpec[] {
  const claude = launcher("CMUX_NEXT_CLAUDE_ACP", "@agentclientprotocol/claude-agent-acp");
  const codex = launcher("CMUX_NEXT_CODEX_ACP", "@agentclientprotocol/codex-acp");
  return [
    { id: "claude", name: "Claude Code", ...claude, detect: claudeLoggedIn, initials: "CC", tint: "#D97757" },
    { id: "codex", name: "Codex", ...codex, detect: codexLoggedIn, initials: "CX", tint: "#10A37F" },
  ];
}
