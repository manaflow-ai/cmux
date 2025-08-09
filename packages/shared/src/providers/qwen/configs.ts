import type { AgentConfig } from "../../agentConfig.js";
import { QWEN_API_KEY } from "../../apiKeys.js";
import { checkQwenRequirements } from "./check-requirements.js";
import { getQwenEnvironment } from "./environment.js";

export const QWEN_CODE_CONFIG: AgentConfig = {
  name: "qwen/code",
  command: "bunx",
  args: [
    "@qwen-code/qwen-code@latest",
    "$PROMPT",
  ],
  environment: getQwenEnvironment,
  apiKeys: [QWEN_API_KEY],
  checkRequirements: checkQwenRequirements,
};