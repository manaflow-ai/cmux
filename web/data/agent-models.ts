export interface AgentModelChoice {
  value: string;
  label: string;
  description?: string;
}

export interface AgentModelServiceTier {
  id: string;
  name: string;
  description?: string;
}

export interface AgentModel {
  id: string;
  label: string;
  description?: string;
  contextWindow?: number;
  supportsOneMillion?: boolean;
  fast?: boolean;
  minVersion?: string;
  deprecated?: boolean;
  efforts?: AgentModelChoice[];
  defaultEffort?: string;
  serviceTiers?: AgentModelServiceTier[];
  defaultServiceTier?: string | null;
  isDefault?: boolean;
}

export interface AgentModelProvider {
  defaultModel: string;
  models: AgentModel[];
}

export interface AgentModelCatalog {
  schemaVersion: 1;
  updatedAt: string;
  providers: {
    claude: AgentModelProvider;
    codex: AgentModelProvider;
    gemini: AgentModelProvider;
    opencode?: AgentModelProvider;
    pi?: AgentModelProvider;
  };
}

export const agentModelCatalog = {
  schemaVersion: 1,
  updatedAt: "2026-09-14T00:00:00.000Z",
  providers: {
    claude: {
      defaultModel: "claude-sonnet-5",
      models: [
        {
          id: "claude-fable-5",
          label: "Claude Fable 5",
          contextWindow: 200000,
          supportsOneMillion: true,
          minVersion: "2.1.169",
        },
        {
          id: "claude-opus-4-8",
          label: "Claude Opus 4.8",
          contextWindow: 200000,
          fast: true,
          minVersion: "2.1.154",
        },
        {
          id: "claude-opus-4-7",
          label: "Claude Opus 4.7",
          contextWindow: 200000,
          fast: true,
          minVersion: "2.1.111",
        },
        {
          id: "claude-opus-4-6",
          label: "Claude Opus 4.6",
          contextWindow: 200000,
          supportsOneMillion: true,
          fast: true,
        },
        {
          id: "claude-opus-4-5",
          label: "Claude Opus 4.5",
          contextWindow: 200000,
          fast: true,
        },
        {
          id: "claude-sonnet-5",
          label: "Claude Sonnet 5",
          contextWindow: 200000,
          supportsOneMillion: true,
        },
        {
          id: "claude-sonnet-4-6",
          label: "Claude Sonnet 4.6",
          contextWindow: 200000,
          supportsOneMillion: true,
        },
        {
          id: "claude-haiku-4-5",
          label: "Claude Haiku 4.5",
          contextWindow: 200000,
        },
      ],
    },
    codex: {
      defaultModel: "gpt-6-astra",
      models: [
        {
          id: "gpt-6-astra",
          label: "GPT-6-Astra",
          description: "Our most capable model for complex, demanding work.",
          contextWindow: 272000,
          isDefault: true,
        },
        {
          id: "gpt-5.6-sol",
          label: "GPT-5.6-Sol",
          description: "Reliable agentic workhorse for everyday tasks.",
          contextWindow: 272000,
        },
        {
          id: "gpt-5.6-terra",
          label: "GPT-5.6-Terra",
          description: "Balanced agentic coding model for everyday work.",
          contextWindow: 272000,
        },
        {
          id: "gpt-5.6-luna",
          label: "GPT-5.6-Luna",
          description: "Fast and affordable agentic coding model.",
          contextWindow: 272000,
        },
        {
          id: "gpt-5.5",
          label: "GPT-5.5",
          description: "Proven previous-generation model for coding and general work.",
          contextWindow: 272000,
        },
      ],
    },
    opencode: {
      defaultModel: "anthropic/claude-sonnet-5",
      models: [
        { id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5" },
        { id: "anthropic/claude-opus-4-8", label: "Claude Opus 4.8" },
        { id: "openai/gpt-5.5", label: "GPT-5.5" },
      ],
    },
    gemini: {
      defaultModel: "gemini-3.1-pro-preview",
      models: [
        { id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview" },
        { id: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview" },
        { id: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview" },
        { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
        { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
        { id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite" },
      ],
    },
  },
} as const satisfies AgentModelCatalog;
