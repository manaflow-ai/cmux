import type { AgentConfig } from "../../agentConfig.js";
import { CURSOR_API_KEY } from "../../apiKeys.js";
import { checkCursorRequirements } from "./check-requirements.js";
import { getCursorEnvironment } from "./environment.js";

export const CURSOR_OPUS_4_1_CONFIG: AgentConfig = {
  name: "cursor/opus-4.1",
  // Use wrapper that writes NDJSON to /root/lifecycle for completion detection
  command: "/root/.local/bin/cursor-agent",
  // Force stream-json output and pass the prompt as final arg
  args: ["--force", "--model", "opus-4.1", "$PROMPT"],
  environment: getCursorEnvironment,
  checkRequirements: checkCursorRequirements,
  apiKeys: [CURSOR_API_KEY],
  waitForString: "Ready",
};

export const CURSOR_GPT_5_CONFIG: AgentConfig = {
  name: "cursor/gpt-5",
  command: "/root/.local/bin/cursor-agent",
  args: ["--force", "--model", "gpt-5", "$PROMPT"],
  environment: getCursorEnvironment,
  checkRequirements: checkCursorRequirements,
  apiKeys: [CURSOR_API_KEY],
  waitForString: "Ready",
};

export const CURSOR_SONNET_4_CONFIG: AgentConfig = {
  name: "cursor/sonnet-4",
  command: "/root/.local/bin/cursor-agent",
  args: ["--force", "--model", "sonnet-4", "$PROMPT"],
  environment: getCursorEnvironment,
  checkRequirements: checkCursorRequirements,
  apiKeys: [CURSOR_API_KEY],
  waitForString: "Ready",
};

export const CURSOR_SONNET_4_THINKING_CONFIG: AgentConfig = {
  name: "cursor/sonnet-4-thinking",
  command: "/root/.local/bin/cursor-agent",
  args: ["--force", "--model", "sonnet-4-thinking", "$PROMPT"],
  environment: getCursorEnvironment,
  checkRequirements: checkCursorRequirements,
  apiKeys: [CURSOR_API_KEY],
  waitForString: "Ready",
};
