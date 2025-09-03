import type {
  EnvironmentContext,
  EnvironmentResult,
} from "./providers/common/environment-result.js";

import { AMP_CONFIG, AMP_GPT_5_CONFIG } from "./providers/amp/configs.js";
import {
  CLAUDE_OPUS_4_1_CONFIG,
  CLAUDE_OPUS_4_CONFIG,
  CLAUDE_SONNET_CONFIG,
} from "./providers/anthropic/configs.js";
import {
  AUGMENT_GPT_5_CONFIG,
  AUGMENT_CLAUDE_SONNET_4_CONFIG,
} from "./providers/augment/configs.js";
import {
  CURSOR_GPT_5_CONFIG,
  CURSOR_OPUS_4_1_CONFIG,
  CURSOR_SONNET_4_CONFIG,
  CURSOR_SONNET_4_THINKING_CONFIG,
} from "./providers/cursor/configs.js";
import {
  GEMINI_FLASH_CONFIG,
  GEMINI_PRO_CONFIG,
} from "./providers/gemini/configs.js";
import {
  CODEX_GPT_4_1_CONFIG,
  CODEX_GPT_5_CONFIG,
  CODEX_GPT_5_HIGH_REASONING_CONFIG,
  CODEX_O3_CONFIG,
  CODEX_O4_MINI_CONFIG,
} from "./providers/openai/configs.js";
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
} from "./providers/opencode/configs.js";
import {
  QWEN_MODEL_STUDIO_CODER_PLUS_CONFIG,
  QWEN_OPENROUTER_CODER_FREE_CONFIG,
} from "./providers/qwen/configs.js";

export { checkDockerStatus } from "./providers/common/check-docker.js";
export { checkGitStatus } from "./providers/common/check-git.js";

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

export interface AgentConfig {
  name: string;
  command: string;
  args: string[];
  apiKeys?: AgentConfigApiKeys;
  environment?: (ctx: EnvironmentContext) => Promise<EnvironmentResult>;
  waitForString?: string;
  enterKeySequence?: string; // Custom enter key sequence, defaults to "\r"
  checkRequirements?: () => Promise<string[]>; // Returns list of missing requirements
  completionDetector?: (taskRunId: string) => Promise<void>;
}

export const AGENT_CONFIGS: AgentConfig[] = [
  CLAUDE_SONNET_CONFIG,
  CLAUDE_OPUS_4_1_CONFIG,
  CLAUDE_OPUS_4_CONFIG,
  CODEX_GPT_5_CONFIG,
  CODEX_GPT_5_HIGH_REASONING_CONFIG,
  CODEX_O3_CONFIG,
  CODEX_O4_MINI_CONFIG,
  CODEX_GPT_4_1_CONFIG,
  GEMINI_FLASH_CONFIG,
  GEMINI_PRO_CONFIG,
  QWEN_OPENROUTER_CODER_FREE_CONFIG,
  QWEN_MODEL_STUDIO_CODER_PLUS_CONFIG,
  AMP_CONFIG,
  AMP_GPT_5_CONFIG,
  AUGMENT_GPT_5_CONFIG,
  AUGMENT_CLAUDE_SONNET_4_CONFIG,
  OPENCODE_SONNET_CONFIG,
  OPENCODE_OPUS_CONFIG,
  OPENCODE_OPUS_4_1_20250805_CONFIG,
  OPENCODE_KIMI_K2_CONFIG,
  OPENCODE_QWEN3_CODER_CONFIG,
  OPENCODE_GLM_Z1_32B_FREE_CONFIG,
  OPENCODE_GROK_CODE_CONFIG,
  OPENCODE_O3_PRO_CONFIG,
  OPENCODE_GPT_5_CONFIG,
  OPENCODE_GPT_5_MINI_CONFIG,
  OPENCODE_GPT_5_NANO_CONFIG,
  OPENCODE_GPT_OSS_120B_CONFIG,
  OPENCODE_GPT_OSS_20B_CONFIG,
  CURSOR_OPUS_4_1_CONFIG,
  CURSOR_GPT_5_CONFIG,
  CURSOR_SONNET_4_CONFIG,
  CURSOR_SONNET_4_THINKING_CONFIG,
];
