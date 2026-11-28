export type ClientConfigFlagValue = boolean | string;

export type ClientConfig = {
  readonly featureFlags: Record<string, ClientConfigFlagValue>;
  readonly featureFlagPayloads: Record<string, unknown>;
  readonly errorsWhileComputingFlags: boolean;
  readonly requestId?: string;
};

export type ClientConfigEvaluationContext = {
  readonly groups?: Record<string, unknown>;
  readonly personProperties?: Record<string, unknown>;
  readonly groupProperties?: Record<string, unknown>;
  readonly anonDistinctId?: string;
  readonly deviceId?: string;
  readonly timezone?: string;
  readonly evaluationContexts?: readonly string[];
};
