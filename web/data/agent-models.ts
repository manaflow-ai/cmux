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

/**
 * What the model catalog (services/model-catalog, the one source of Claude and Codex models,
 * cx-miuo) does not carry, for the agent-chat payload: the Claude Code version a model needs and
 * the models with a 1M context choice. Keyed by catalog model id.
 */
export const agentModelExtras: Record<string, Pick<AgentModel, "minVersion" | "supportsOneMillion">> = {
  "claude-fable-5": { minVersion: "2.1.169", supportsOneMillion: true },
  "claude-opus-4-8": { minVersion: "2.1.154" },
  "claude-opus-4-7": { minVersion: "2.1.111" },
  "claude-opus-4-6": { supportsOneMillion: true },
  "claude-sonnet-5": { supportsOneMillion: true },
  "claude-sonnet-4-6": { supportsOneMillion: true },
};

/** The providers the model catalog has no curated list for. */
export const otherAgentModelProviders: Pick<AgentModelCatalog["providers"], "opencode" | "gemini"> = {
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
};
