import type { AgentConfigApiKey } from "./agentConfig.js";

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

export const QWEN_API_KEY: AgentConfigApiKey = {
  envVar: "QWEN_API_KEY",
  displayName: "Qwen API Key",
  description: "API key for Qwen code models",
};