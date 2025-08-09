import type { AgentConfig } from "../../agentConfig.js";
import { OPENAI_API_KEY } from "../../apiKeys.js";
import { checkQwenCodeRequirements } from "./check-requirements.js";
import { getQwenCodeEnvironment } from "./environment.js";

export const QWEN_CODE_CONFIG: AgentConfig = {
  name: "qwen-code",
  command: "bunx",
  args: ["@qwen-code/qwen-code@latest", "$PROMPT"],
  environment: getQwenCodeEnvironment,
  checkRequirements: checkQwenCodeRequirements,
  apiKeys: [OPENAI_API_KEY],
};