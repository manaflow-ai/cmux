// GET /api/agent-models, the classic agent-chat sidecar's model list (agent-chat/catalog.ts), as a
// projection of the model catalog: its Claude, Codex and Gemini models are the catalog's, in its order
// (cx-miuo, ownership audit V-2). data/agent-models.ts adds only what the catalog does not carry.

import {
  agentModelExtras,
  otherAgentModelProviders,
  type AgentModel,
  type AgentModelCatalog,
  type AgentModelProvider,
} from "../../data/agent-models";
import type { ModelCatalog } from "./types";

const ONE_MILLION = 1_000_000;

function provider(catalog: ModelCatalog, harnessId: string): AgentModelProvider {
  const harness = catalog.harnesses.find((entry) => entry.id === harnessId);
  if (!harness || harness.models.length === 0) throw new Error(`model catalog has no ${harnessId} models`);
  const defaultModel = harness.models.some((model) => model.id === harness.defaultModel)
    ? harness.defaultModel!
    : harness.models[0].id;
  const models = harness.models.map((model): AgentModel => {
    const contextWindow = model.ref ? catalog.models[model.ref]?.contextWindow : undefined;
    const extras = agentModelExtras[model.id] ?? {};
    // The 1M choice is a Claude Code setting; other harnesses run the model's own window.
    const oneMillion = harnessId === "claude" && (extras.supportsOneMillion || (contextWindow ?? 0) >= ONE_MILLION);
    return {
      id: model.id,
      label: model.name,
      ...(contextWindow ? { contextWindow } : {}),
      ...(oneMillion ? { supportsOneMillion: true } : {}),
      ...(model.fast ? { fast: true } : {}),
      ...(extras.minVersion ? { minVersion: extras.minVersion } : {}),
      ...(model.status === "deprecated" ? { deprecated: true } : {}),
      ...(model.id === defaultModel ? { isDefault: true } : {}),
    };
  });
  return { defaultModel, models };
}

/** The agent-chat payload for `catalog`. */
export function agentModelsFromCatalog(catalog: ModelCatalog): AgentModelCatalog {
  return {
    schemaVersion: 1,
    updatedAt: catalog.generatedAt,
    providers: {
      claude: provider(catalog, "claude"),
      codex: provider(catalog, "codex"),
      gemini: provider(catalog, "gemini"),
      ...otherAgentModelProviders,
    },
  };
}
