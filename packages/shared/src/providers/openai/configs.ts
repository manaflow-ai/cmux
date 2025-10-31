import type { AgentConfig } from "../../agentConfig";
import { OPENAI_API_KEY } from "../../apiKeys";
import { applyOpenAIApiKeys } from "./apply-api-keys";
import { checkOpenAIRequirements } from "./check-requirements";
// Lazy-load Node-only completion detector to avoid bundling fs in browser
import { startCodexCompletionDetector } from "./completion-detector";
import { getOpenAIEnvironment } from "./environment";

export const CODEX_GPT_5_CONFIG: AgentConfig = {
  name: "codex/gpt-5",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_HIGH_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-high",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="high"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_MEDIUM_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-medium",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="medium"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_LOW_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-low",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="low"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_MINIMAL_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-minimal",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="minimal"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_O3_CONFIG: AgentConfig = {
  name: "codex/o3",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "o3",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_O4_MINI_CONFIG: AgentConfig = {
  name: "codex/o4-mini",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "o4-mini",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_4_1_CONFIG: AgentConfig = {
  name: "codex/gpt-4.1",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-4.1",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_CODEX_LOW_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-codex-low",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5-codex",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="low"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_CODEX_MEDIUM_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-codex-medium",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5-codex",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="medium"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};

export const CODEX_GPT_5_CODEX_HIGH_REASONING_CONFIG: AgentConfig = {
  name: "codex/gpt-5-codex-high",
  command: "bunx",
  args: [
    "@openai/codex@latest",
    "--model",
    "gpt-5-codex",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    'model_reasoning_effort="high"',
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
  applyApiKeys: applyOpenAIApiKeys,
  completionDetector: startCodexCompletionDetector,
};
