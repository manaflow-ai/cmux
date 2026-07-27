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

const CODEX_REASONING_EFFORTS: AgentModelChoice[] = [
  { value: "none", label: "none" },
  { value: "low", label: "low" },
  { value: "medium", label: "medium" },
  { value: "high", label: "high" },
  { value: "xhigh", label: "xhigh" },
];

export const agentModelCatalog = {
  schemaVersion: 1,
  updatedAt: "2026-07-09T00:00:00.000Z",
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
      defaultModel: "gpt-5.5",
      models: [
        {
          id: "gpt-5.5",
          label: "GPT-5.5",
          description: "Frontier model for complex coding, computer use, knowledge work, and research workflows in Codex.",
          contextWindow: 1050000,
          supportsOneMillion: true,
          efforts: CODEX_REASONING_EFFORTS,
          defaultEffort: "medium",
          isDefault: true,
        },
        {
          id: "gpt-5.5-pro",
          label: "GPT-5.5 Pro",
          description: "Higher-capability GPT-5.5 model for difficult professional work.",
          contextWindow: 1050000,
          supportsOneMillion: true,
          efforts: CODEX_REASONING_EFFORTS,
          defaultEffort: "medium",
        },
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
