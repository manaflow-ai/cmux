import type { AgentConfigApiKey } from "./agentConfig";

export const ANTHROPIC_API_KEY: AgentConfigApiKey = {
  envVar: "ANTHROPIC_API_KEY",
  displayName: "Anthropic API Key",
  description: "Anthropic API Key",
};

export const OPENAI_API_KEY: AgentConfigApiKey = {
  envVar: "OPENAI_API_KEY",
  displayName: "OpenAI API Key",
  description: "OpenAI API Key",
};

export const OPENROUTER_API_KEY: AgentConfigApiKey = {
  envVar: "OPENROUTER_API_KEY",
  displayName: "OpenRouter API Key",
  description: "OpenRouter API Key",
};

export const GEMINI_API_KEY: AgentConfigApiKey = {
  envVar: "GEMINI_API_KEY",
  displayName: "Gemini API Key",
  description: "API key for Google Gemini AI models",
};

export const AMP_API_KEY: AgentConfigApiKey = {
  envVar: "AMP_API_KEY",
  displayName: "AMP API Key",
  description: "API key for Sourcegraph AMP",
};

export const CURSOR_API_KEY: AgentConfigApiKey = {
  envVar: "CURSOR_API_KEY",
  displayName: "Cursor API Key",
  description: "API key for Cursor agent",
};

export const MODEL_STUDIO_API_KEY: AgentConfigApiKey = {
  envVar: "MODEL_STUDIO_API_KEY",
  displayName: "Alibaba Cloud ModelStudio API Key",
  description: "Alibaba Cloud ModelStudio (DashScope Intl) API key for Qwen",
};

export const XAI_API_KEY: AgentConfigApiKey = {
  envVar: "XAI_API_KEY",
  displayName: "xAI API Key",
  description: "API key for xAI Grok models",
};

export const CLAUDE_CODE_OAUTH_TOKEN: AgentConfigApiKey = {
  envVar: "CLAUDE_CODE_OAUTH_TOKEN",
  displayName: "Claude OAuth Token",
  description:
    "OAuth token from Claude Code CLI. Run `claude setup-token` and paste the output here. Preferred over Anthropic API key when set.",
};
