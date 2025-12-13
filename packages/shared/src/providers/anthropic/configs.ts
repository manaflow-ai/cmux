import type { AgentConfig } from "../../agentConfig";
import { ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN } from "../../apiKeys";
import { checkClaudeRequirements } from "./check-requirements";
import { startClaudeCompletionDetector } from "./completion-detector";
import {
  CLAUDE_KEY_ENV_VARS_TO_UNSET,
  getClaudeEnvironment,
} from "./environment";

/**
 * Apply API keys for Claude agents.
 *
 * Priority:
 * 1. If CLAUDE_CODE_OAUTH_TOKEN is set, use it and unset ANTHROPIC_API_KEY
 * 2. Otherwise, fall back to ANTHROPIC_API_KEY
 *
 * The OAuth token is preferred because it uses the user's own Claude subscription
 * and bypasses the need for an API key entirely.
 */
const applyClaudeApiKeys: NonNullable<AgentConfig["applyApiKeys"]> = async (
  keys,
) => {
  const oauthToken = keys.CLAUDE_CODE_OAUTH_TOKEN;
  const anthropicKey = keys.ANTHROPIC_API_KEY;

  // Always unset these to prevent conflicts
  const unsetEnv = [...CLAUDE_KEY_ENV_VARS_TO_UNSET];

  // If OAuth token is set, ensure ANTHROPIC_API_KEY is also unset
  if (oauthToken && oauthToken.trim().length > 0) {
    // Ensure ANTHROPIC_API_KEY is in the unset list (it already should be from CLAUDE_KEY_ENV_VARS_TO_UNSET)
    if (!unsetEnv.includes("ANTHROPIC_API_KEY")) {
      unsetEnv.push("ANTHROPIC_API_KEY");
    }
    return {
      env: {
        CLAUDE_CODE_OAUTH_TOKEN: oauthToken,
      },
      unsetEnv,
    };
  }

  // Fall back to ANTHROPIC_API_KEY if no OAuth token
  if (anthropicKey && anthropicKey.trim().length > 0) {
    // Note: We still unset ANTHROPIC_API_KEY here because getClaudeEnvironment
    // handles the key via settings.json (anthropicApiKey) instead of env var
    return {
      unsetEnv,
    };
  }

  return {
    unsetEnv,
  };
};

export const CLAUDE_SONNET_4_CONFIG: AgentConfig = {
  name: "claude/sonnet-4",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-sonnet-4-20250514",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};

export const CLAUDE_OPUS_4_CONFIG: AgentConfig = {
  name: "claude/opus-4",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-opus-4-20250514",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};

export const CLAUDE_OPUS_4_1_CONFIG: AgentConfig = {
  name: "claude/opus-4.1",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-opus-4-1-20250805",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};

export const CLAUDE_OPUS_4_5_CONFIG: AgentConfig = {
  name: "claude/opus-4.5",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-opus-4-5",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};

export const CLAUDE_SONNET_4_5_CONFIG: AgentConfig = {
  name: "claude/sonnet-4.5",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-sonnet-4-5-20250929",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};

export const CLAUDE_HAIKU_4_5_CONFIG: AgentConfig = {
  name: "claude/haiku-4.5",
  command: "bunx",
  args: [
    "@anthropic-ai/claude-code@latest",
    "--model",
    "claude-haiku-4-5-20251001",
    "--dangerously-skip-permissions",
    "--ide",
    "$PROMPT",
  ],
  environment: getClaudeEnvironment,
  checkRequirements: checkClaudeRequirements,
  apiKeys: [CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY],
  applyApiKeys: applyClaudeApiKeys,
  completionDetector: startClaudeCompletionDetector,
};
