// The cmux model catalog (schemaVersion 1): the payload GET /api/models/v1 serves and acpmux
// caches for every client. Contract: .cmux-scratch/nx-model-catalog/CONTRACT.md (section 2). The app host adds
// `delivery` and `diagnostics`; the server never sets them.

export type EffortValue = "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
/** "disabled": turned off by the live catalog's kill switch (cloud-api /v1/models/catalog); clients hide it. */
export type ModelStatus = "preview" | "deprecated" | "disabled";
export type InputModality = "text" | "image" | "pdf" | "audio" | "video";

export interface ModelInfo {
  name: string;
  family?: string;
  releaseDate?: string;
  knowledge?: string;
  contextWindow?: number;
  maxOutput?: number;
  input?: InputModality[];
  reasoning?: boolean;
  toolCall?: boolean;
  openWeights?: boolean;
  cost?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number };
  status?: ModelStatus;
}

export interface HarnessModel {
  id: string;
  ref?: string;
  name: string;
  shortName: string;
  family?: string;
  provider?: string;
  efforts?: EffortValue[];
  defaultEffort?: EffortValue;
  fast?: boolean;
  aliases?: string[];
  status?: ModelStatus;
  /** Why a model is "disabled" (the kill switch's reason), for a tooltip. */
  statusReason?: string;
}

/** The feed rules a "catalog" harness's models come from, so a client that reads the public feed
 *  itself (acpmux, every hour) lists a model the day the feed has it, before this catalog is
 *  rebuilt. Same meaning as overrides.ts `HarnessSource` and the override fields named here. */
export interface HarnessFeed {
  sources: { provider: string; include?: string[]; exclude?: string[]; minReleaseDate?: string }[];
  shortNamePrefix?: string;
  familyNames?: Record<string, string>;
  dropEfforts?: EffortValue[];
  defaultEffort?: EffortValue;
  groupByProvider?: boolean;
  /** Feed models this harness never lists (overrides.ts `hidden`). */
  hidden?: string[];
}

export interface CatalogHarness {
  id: string;
  name: string;
  brand: string;
  families: string[];
  modelSource: "catalog" | "probe";
  /** Where to install or sign in: https on a host allowlist (schema.ts DOCS_URL_HOSTS). */
  docsUrl?: string;
  defaultModel?: string;
  /** The harness runs any model id its provider serves (Gemini CLI's `--model`), so a picker
   *  offers the catalog's models even when the harness's own menu does not name them. */
  runsAnyModel?: boolean;
  feed?: HarnessFeed;
  models: HarnessModel[];
}

export interface ModelCatalog {
  schemaVersion: 1;
  generatedAt: string;
  source: "live" | "snapshot";
  harnesses: CatalogHarness[];
  models: Record<string, ModelInfo>;
  providers: Record<string, { name: string }>;
}
