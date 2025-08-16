import type { AgentConfig } from "../../agentConfig.js";
import { OPENAI_API_KEY } from "../../apiKeys.js";
import { checkOpenAIRequirements } from "./check-requirements.js";
import { getOpenAIEnvironment } from "./environment.js";

export const CODEX_GPT_5_CONFIG: AgentConfig = {
  name: "codex/gpt-5",
  command: "bunx",
  args: [
    "@openai/codex",
    "--model",
    "gpt-5",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    // Write each notification JSON payload (one per agent turn) to a JSONL file in the workspace
    // No jq dependency to keep it portable inside the worker container
    // NOTE: With sh -lc, the first argument becomes $0, not $1
    "notify=[\"sh\",\"-lc\",\"printf '%s\\n' \\\"$0\\\" | tee -a ./codex-turns.jsonl >/dev/null\"]",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
};

export const CODEX_O3_CONFIG: AgentConfig = {
  name: "codex/o3",
  command: "bunx",
  args: [
    "@openai/codex",
    "--model",
    "o3",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    "notify=[\"sh\",\"-lc\",\"printf '%s\\n' \\\"$0\\\" | tee -a ./codex-turns.jsonl >/dev/null\"]",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
};

export const CODEX_O4_MINI_CONFIG: AgentConfig = {
  name: "codex/o4-mini",
  command: "bunx",
  args: [
    "@openai/codex",
    "--model",
    "o4-mini",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    "notify=[\"sh\",\"-lc\",\"printf '%s\\n' \\\"$0\\\" | tee -a ./codex-turns.jsonl >/dev/null\"]",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
};

export const CODEX_GPT_4_1_CONFIG: AgentConfig = {
  name: "codex/gpt-4.1",
  command: "bunx",
  args: [
    "@openai/codex",
    "--model",
    "gpt-4.1",
    "--sandbox",
    "danger-full-access",
    "--ask-for-approval",
    "never",
    "-c",
    "notify=[\"sh\",\"-lc\",\"printf '%s\\n' \\\"$0\\\" | tee -a ./codex-turns.jsonl >/dev/null\"]",
    "$PROMPT",
  ],
  environment: getOpenAIEnvironment,
  checkRequirements: checkOpenAIRequirements,
  apiKeys: [OPENAI_API_KEY],
};
