import type {
  EnvironmentContext,
  EnvironmentResult,
} from "./providers/common/environment-result";

import { AMP_CONFIG, AMP_GPT_5_CONFIG } from "./providers/amp/configs";
import {
  CLAUDE_OPUS_4_1_CONFIG,
  CLAUDE_OPUS_4_CONFIG,
  CLAUDE_SONNET_4_CONFIG,
  CLAUDE_SONNET_4_5_CONFIG,
} from "./providers/anthropic/configs";
import {
  CURSOR_GPT_5_CONFIG,
  CURSOR_OPUS_4_1_CONFIG,
  CURSOR_SONNET_4_CONFIG,
  CURSOR_SONNET_4_THINKING_CONFIG,
} from "./providers/cursor/configs";
import {
  GEMINI_FLASH_CONFIG,
  GEMINI_PRO_CONFIG,
} from "./providers/gemini/configs";
import {
  CODEX_GPT_4_1_CONFIG,
  CODEX_GPT_5_CODEX_HIGH_REASONING_CONFIG,
  CODEX_GPT_5_CODEX_LOW_REASONING_CONFIG,
  CODEX_GPT_5_CODEX_MEDIUM_REASONING_CONFIG,
  CODEX_GPT_5_HIGH_REASONING_CONFIG,
  CODEX_GPT_5_LOW_REASONING_CONFIG,
  CODEX_GPT_5_MEDIUM_REASONING_CONFIG,
  CODEX_GPT_5_MINIMAL_REASONING_CONFIG,
  CODEX_O3_CONFIG,
  CODEX_O4_MINI_CONFIG,
} from "./providers/openai/configs";
import {
  OPENCODE_GLM_Z1_32B_FREE_CONFIG,
  OPENCODE_GPT_5_CONFIG,
  OPENCODE_GPT_5_MINI_CONFIG,
  OPENCODE_GPT_5_NANO_CONFIG,
  OPENCODE_GPT_OSS_120B_CONFIG,
  OPENCODE_GPT_OSS_20B_CONFIG,
  OPENCODE_GROK_CODE_CONFIG,
  OPENCODE_KIMI_K2_CONFIG,
  OPENCODE_O3_PRO_CONFIG,
  OPENCODE_OPUS_4_1_20250805_CONFIG,
  OPENCODE_OPUS_CONFIG,
  OPENCODE_QWEN3_CODER_CONFIG,
  OPENCODE_SONNET_CONFIG,
} from "./providers/opencode/configs";
import {
  QWEN_MODEL_STUDIO_CODER_PLUS_CONFIG,
  QWEN_OPENROUTER_CODER_FREE_CONFIG,
} from "./providers/qwen/configs";

export { checkGitStatus } from "./providers/common/check-git";

export { type EnvironmentResult };

export type AgentConfigApiKey = {
  envVar: string;
  displayName: string;
  description?: string;
  // Optionally inject this key value under a different environment variable
  // name when launching the agent process.
  mapToEnvVar?: string;
};
export type AgentConfigApiKeys = Array<AgentConfigApiKey>;

export type ProviderRequirementsContext = {
  apiKeys?: Record<string, string>;
  teamSlugOrId?: string;
};

export interface AgentConfig {
  name: string;
  command: string;
  args: string[];
  apiKeys?: AgentConfigApiKeys;
  environment?: (ctx: EnvironmentContext) => Promise<EnvironmentResult>;
  applyApiKeys?: (
    keys: Record<string, string>,
  ) => Promise<Partial<EnvironmentResult>> | Partial<EnvironmentResult>; // Optional hook to apply API keys into env/files/startup commands instead of default env var injection
  waitForString?: string;
  enterKeySequence?: string; // Custom enter key sequence, defaults to "\r"
  checkRequirements?: (
    context?: ProviderRequirementsContext,
  ) => Promise<string[]>; // Returns list of missing requirements
  completionDetector?: (taskRunId: string) => Promise<void>;
}

export const AGENT_CONFIGS: AgentConfig[] = [
  CLAUDE_SONNET_4_5_CONFIG,
  CLAUDE_OPUS_4_1_CONFIG,
  CLAUDE_SONNET_4_CONFIG,
  CLAUDE_OPUS_4_CONFIG,
  CODEX_GPT_5_CODEX_HIGH_REASONING_CONFIG,
  CODEX_GPT_5_CODEX_MEDIUM_REASONING_CONFIG,
  CODEX_GPT_5_CODEX_LOW_REASONING_CONFIG,
  CODEX_GPT_5_HIGH_REASONING_CONFIG,
  CODEX_GPT_5_MEDIUM_REASONING_CONFIG,
  CODEX_GPT_5_LOW_REASONING_CONFIG,
  CODEX_GPT_5_MINIMAL_REASONING_CONFIG,
  CODEX_O3_CONFIG,
  CODEX_O4_MINI_CONFIG,
  CODEX_GPT_4_1_CONFIG,
  AMP_CONFIG,
  AMP_GPT_5_CONFIG,
  OPENCODE_GROK_CODE_CONFIG,
  OPENCODE_SONNET_CONFIG,
  OPENCODE_OPUS_CONFIG,
  OPENCODE_OPUS_4_1_20250805_CONFIG,
  OPENCODE_KIMI_K2_CONFIG,
  OPENCODE_QWEN3_CODER_CONFIG,
  OPENCODE_GLM_Z1_32B_FREE_CONFIG,
  OPENCODE_O3_PRO_CONFIG,
  OPENCODE_GPT_5_CONFIG,
  OPENCODE_GPT_5_MINI_CONFIG,
  OPENCODE_GPT_5_NANO_CONFIG,
  OPENCODE_GPT_OSS_120B_CONFIG,
  OPENCODE_GPT_OSS_20B_CONFIG,
  GEMINI_FLASH_CONFIG,
  GEMINI_PRO_CONFIG,
  QWEN_OPENROUTER_CODER_FREE_CONFIG,
  QWEN_MODEL_STUDIO_CODER_PLUS_CONFIG,
  CURSOR_OPUS_4_1_CONFIG,
  CURSOR_GPT_5_CONFIG,
  CURSOR_SONNET_4_CONFIG,
  CURSOR_SONNET_4_THINKING_CONFIG,
];
