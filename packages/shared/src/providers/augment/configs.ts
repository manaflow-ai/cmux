import type { AgentConfig } from "../../agentConfig.js";
import { checkAugmentRequirements } from "./check-requirements.js";
import { startAugmentCompletionDetector } from "./completion-detector.js";
import { getAugmentEnvironment } from "./environment.js";

export const AUGMENT_GPT_5_CONFIG: AgentConfig = {
  name: "augment/gpt-5",
  command: "auggie",
  args: ["--model", "gpt5", "$PROMPT"],
  environment: getAugmentEnvironment,
  checkRequirements: checkAugmentRequirements,
  completionDetector: startAugmentCompletionDetector,
};

export const AUGMENT_CLAUDE_SONNET_4_CONFIG: AgentConfig = {
  name: "augment/claude-sonnet-4",
  command: "auggie",
  args: ["--model", "sonnet4", "$PROMPT"],
  environment: getAugmentEnvironment,
  checkRequirements: checkAugmentRequirements,
  completionDetector: startAugmentCompletionDetector,
};
