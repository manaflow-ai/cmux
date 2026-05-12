/**
 * Discover OAuth credentials from other agentic CLIs already installed on this
 * machine. Lets cmux101 work out-of-the-box for users who already pay for
 * Claude Code or ChatGPT.
 *
 * macOS: keychain via `security`
 * Linux: ~/.config/<tool>/auth.json
 * Windows: not yet (cred manager TBD)
 *
 * The returned shapes match what each provider adapter expects to consume.
 */

import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Claude Code OAuth (macOS keychain "Claude Code-credentials")
// ---------------------------------------------------------------------------

export interface ClaudeOAuth {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
  scopes?: string[];
  subscriptionType?: string;
}

export function loadClaudeOAuth(): ClaudeOAuth | null {
  if (process.platform === "darwin") {
    const res = spawnSync(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { encoding: "utf-8" },
    );
    if (res.status !== 0) return null;
    try {
      const parsed = JSON.parse(res.stdout) as { claudeAiOauth?: ClaudeOAuth };
      if (parsed.claudeAiOauth?.accessToken) return parsed.claudeAiOauth;
    } catch {
      return null;
    }
    return null;
  }

  // Fallback: ~/.claude/.credentials.json (some Linux installs use this).
  try {
    const path = join(homedir(), ".claude", ".credentials.json");
    const data = JSON.parse(readFileSyncSafe(path) ?? "null") as { claudeAiOauth?: ClaudeOAuth } | null;
    if (data?.claudeAiOauth?.accessToken) return data.claudeAiOauth;
  } catch {
    // ignore
  }
  return null;
}

// ---------------------------------------------------------------------------
// Codex / ChatGPT OAuth (~/.codex/auth.json)
// ---------------------------------------------------------------------------

export interface CodexOAuth {
  authMode: "chatgpt" | "apikey";
  accessToken: string;
  refreshToken?: string;
  idToken?: string;
  accountId?: string;
  lastRefresh?: string;
}

export function loadCodexOAuth(): CodexOAuth | null {
  const path = join(homedir(), ".codex", "auth.json");
  const raw = readFileSyncSafe(path);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as {
      auth_mode?: "chatgpt" | "apikey";
      OPENAI_API_KEY?: string;
      tokens?: {
        access_token?: string;
        refresh_token?: string;
        id_token?: string;
        account_id?: string;
      };
      last_refresh?: string;
    };
    if (parsed.tokens?.access_token) {
      return {
        authMode: parsed.auth_mode ?? "chatgpt",
        accessToken: parsed.tokens.access_token,
        refreshToken: parsed.tokens.refresh_token,
        idToken: parsed.tokens.id_token,
        accountId: parsed.tokens.account_id,
        lastRefresh: parsed.last_refresh,
      };
    }
    if (parsed.OPENAI_API_KEY) {
      return { authMode: "apikey", accessToken: parsed.OPENAI_API_KEY };
    }
  } catch {
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function readFileSyncSafe(path: string): string | null {
  try {
    // We don't import 'fs' at top level to keep cold-start fast for the
    // common case where this module isn't used.
    const fs = require("node:fs") as typeof import("node:fs");
    return fs.readFileSync(path, "utf-8");
  } catch {
    return null;
  }
}

/** Convenience: a single call that returns all discovered credentials. */
export function discoverAllOAuth(): {
  claude: ClaudeOAuth | null;
  codex: CodexOAuth | null;
} {
  return {
    claude: loadClaudeOAuth(),
    codex: loadCodexOAuth(),
  };
}
