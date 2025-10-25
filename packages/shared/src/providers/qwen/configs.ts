import type { AgentConfig } from "../../agentConfig";
import { MODEL_STUDIO_API_KEY, OPENROUTER_API_KEY } from "../../apiKeys";
import {
  checkQwenModelStudioRequirements,
  checkQwenOpenRouterRequirements,
} from "./check-requirements";
import { startQwenCompletionDetector } from "./completion-detector";
import {
  getQwenModelStudioEnvironment,
  getQwenOpenRouterEnvironment,
} from "./environment";

export const QWEN_OPENROUTER_CODER_FREE_CONFIG: AgentConfig = {
  name: "qwen/qwen3-coder:free",
  command: "pnpm",
  args: [
    "dlx",
    "@qwen-code/qwen-code",
    "--telemetry",
    "--telemetry-target=local",
    "--telemetry-otlp-endpoint=",
    "--telemetry-outfile",
    "/tmp/qwen-telemetry-$CMUX_TASK_RUN_ID.log",
    "--telemetry-log-prompts",
    "--prompt-interactive",
    "$PROMPT",
    "--yolo",
    "--model",
    "qwen/qwen3-coder:free",
  ],
  environment: getQwenOpenRouterEnvironment,
  // Use OpenRouter exclusively for Qwen Code authentication.
  // Inject as OPENAI_API_KEY (OpenAI-compatible clients expect this env var).
  apiKeys: [
    {
      ...OPENROUTER_API_KEY,
      mapToEnvVar: "OPENAI_API_KEY",
    },
  ],
  checkRequirements: checkQwenOpenRouterRequirements,
  completionDetector: startQwenCompletionDetector,
};

export const QWEN_MODEL_STUDIO_CODER_PLUS_CONFIG: AgentConfig = {
  name: "qwen/qwen3-coder-plus",
  command: "pnpm",
  args: [
    "dlx",
    "@qwen-code/qwen-code",
    "--telemetry",
    "--telemetry-target=local",
    "--telemetry-otlp-endpoint=",
    "--telemetry-outfile",
    "/tmp/qwen-telemetry-$CMUX_TASK_RUN_ID.log",
    "--telemetry-log-prompts",
    "--prompt-interactive",
    "$PROMPT",
    "--yolo",
    "--model",
    "qwen3-coder-plus",
  ],
  environment: getQwenModelStudioEnvironment,
  // Accept a ModelStudio-specific key in Settings and inject as OPENAI_API_KEY
  // for the OpenAI-compatible client.
  apiKeys: [
    {
      ...MODEL_STUDIO_API_KEY,
      mapToEnvVar: "OPENAI_API_KEY",
    },
  ],
  checkRequirements: checkQwenModelStudioRequirements,
  completionDetector: startQwenCompletionDetector,
};
