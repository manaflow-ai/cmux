// l10n-allow-file: gallery and test fixtures (sample models), not shipped UI.
// The machine in Lawrence's screenshot (via Leo 2026-10-28: "lawrence says search feels confusing
// here in the model picker"): nine harnesses, and "sol 6.1" matching GPT-6.1 Sol through Codex,
// OpenCode and Pi, two OpenCode routes that read the same, and Pi's long OpenRouter names that
// differ only at their end.
import type { ModelPickerProps } from "../../agent-session/acpmux/modelPickerLayout";

const claudeModels = [
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-haiku-5-5", name: "Haiku 5.5" },
];

export const SOL_SEARCH_CATALOG: ModelPickerProps["catalog"] = [
  { id: "claude", name: "Claude Code", models: claudeModels },
  { id: "claude-acp", name: "Claude Code (acp)", models: claudeModels },
  { id: "claude-sr", name: "Claude Code (sr)", models: claudeModels },
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" },
      { id: "gpt-6-astra", name: "GPT-6 Astra" },
    ],
  },
  { id: "codex-acp", name: "Codex (acp)", models: [{ id: "gpt-6-astra", name: "GPT-6 Astra" }] },
  { id: "codex-app-server", name: "Codex (app-server)", models: [{ id: "gpt-6-luna", name: "GPT-6 Luna" }] },
  {
    id: "opencode",
    name: "OpenCode",
    models: [
      { id: "openrouter/openai/gpt-6.1-sol", name: "GPT-6.1 Sol" },
      { id: "openrouter/openai/gpt-6.1-sol-20261015", name: "GPT-6.1 Sol" },
      { id: "openai/gpt-6.1-sol-fast", name: "GPT-6.1 Sol Fast" },
      { id: "openai/gpt-6.1-sol-ultracode", name: "GPT-6.1 Sol Ultracode (preview, extended reasoning)" },
    ],
  },
  {
    id: "pi",
    name: "Pi",
    models: [
      { id: "openai-codex/gpt-6.1-sol", name: "GPT-6.1 Sol" },
      { id: "openrouter/openai/gpt-6.1-sol-thinking", name: "OpenAI: GPT-6.1 Sol Thinking (extended context)" },
      { id: "openrouter/openai/gpt-6.1-sol-mini", name: "OpenAI: GPT-6.1 Sol Mini (extended context)" },
      { id: "openrouter/openai/gpt-6.1-sol-nano", name: "OpenAI: GPT-6.1 Sol Nano (extended context)" },
    ],
  },
  { id: "gemini", name: "Gemini CLI", models: [{ id: "gemini-3-pro", name: "Gemini 3 Pro" }] },
];

export const SOL_SEARCH_QUERY = "sol 6.1";
