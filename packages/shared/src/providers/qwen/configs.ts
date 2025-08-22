import type { AgentConfig } from "../../agentConfig.js";
import { OPENAI_API_KEY } from "../../apiKeys.js";
import { checkQwenRequirements } from "./check-requirements.js";
import { getQwenEnvironment } from "./environment.js";

// Qwen Code CLI configs. We keep args minimal to avoid agent-specific flags.

export const QWEN_480B_A35B_INSTRUCT_CONFIG: AgentConfig = {
  name: "qwen/Qwen3-Coder-480B-A35B-Instruct",
  command: "bunx",
  args: [
    "@qwen-code/qwen-code",
    "--model",
    "Qwen/Qwen3-Coder-480B-A35B-Instruct",
    "--prompt-interactive",
    "$PROMPT",
  ],
  environment: getQwenEnvironment,
  apiKeys: [OPENAI_API_KEY],
  checkRequirements: checkQwenRequirements,
};

export const QWEN_480B_A35B_INSTRUCT_FP8_CONFIG: AgentConfig = {
  name: "qwen/Qwen3-Coder-480B-A35B-Instruct-FP8",
  command: "bunx",
  args: [
    "@qwen-code/qwen-code",
    "--model",
    "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8",
    "--prompt-interactive",
    "$PROMPT",
  ],
  environment: getQwenEnvironment,
  apiKeys: [OPENAI_API_KEY],
  checkRequirements: checkQwenRequirements,
};

export const QWEN_30B_A3B_INSTRUCT_CONFIG: AgentConfig = {
  name: "qwen/Qwen3-Coder-30B-A3B-Instruct",
  command: "bunx",
  args: [
    "@qwen-code/qwen-code",
    "--model",
    "Qwen/Qwen3-Coder-30B-A3B-Instruct",
    "--prompt-interactive",
    "$PROMPT",
  ],
  environment: getQwenEnvironment,
  apiKeys: [OPENAI_API_KEY],
  checkRequirements: checkQwenRequirements,
};

export const QWEN_30B_A3B_INSTRUCT_FP8_CONFIG: AgentConfig = {
  name: "qwen/Qwen3-Coder-30B-A3B-Instruct-FP8",
  command: "bunx",
  args: [
    "@qwen-code/qwen-code",
    "--model",
    "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8",
    "--prompt-interactive",
    "$PROMPT",
  ],
  environment: getQwenEnvironment,
  apiKeys: [OPENAI_API_KEY],
  checkRequirements: checkQwenRequirements,
};

