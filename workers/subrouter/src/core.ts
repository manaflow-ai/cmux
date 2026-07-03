export const SUBROUTER_SCHEMA_VERSION = 1;

export interface SubrouterEndpointConfig {
  originUrl: string;
  customBaseUrl: string;
  codexBackendUrl: string;
  codexChatGPTBaseUrl: string;
}

export interface SubrouterControlStatus {
  schemaVersion: typeof SUBROUTER_SCHEMA_VERSION;
  service: "cmux-subrouter";
  durableObjectControlPlane: true;
  dataPlaneManagedByCmux: false;
  cloudVmRouterLifecycleManagedByCmux: false;
  freestyleDefaultImageBakesSubrouter: false;
  supportedAgentsToday: ["codex", "hermes"];
  pendingAgents: ["claude", "opencode"];
  updatedAt: string;
}

export function controlStatus(now = new Date()): SubrouterControlStatus {
  return {
    schemaVersion: SUBROUTER_SCHEMA_VERSION,
    service: "cmux-subrouter",
    durableObjectControlPlane: true,
    dataPlaneManagedByCmux: false,
    cloudVmRouterLifecycleManagedByCmux: false,
    freestyleDefaultImageBakesSubrouter: false,
    supportedAgentsToday: ["codex", "hermes"],
    pendingAgents: ["claude", "opencode"],
    updatedAt: now.toISOString(),
  };
}

export function normalizeEndpoint(rawValue: string): SubrouterEndpointConfig | null {
  const trimmed = rawValue.trim().replace(/\/+$/u, "");
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  if (
    (url.protocol !== "http:" && url.protocol !== "https:") ||
    !url.host ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    return null;
  }

  let originUrl = trimmed;
  if (originUrl.endsWith("/v1")) {
    originUrl = originUrl.slice(0, -"/v1".length);
  } else if (originUrl.endsWith("/backend-api/codex")) {
    originUrl = originUrl.slice(0, -"/backend-api/codex".length);
  } else if (originUrl.endsWith("/backend-api")) {
    originUrl = originUrl.slice(0, -"/backend-api".length);
  }
  if (!originUrl) return null;
  return {
    originUrl,
    customBaseUrl: `${originUrl}/v1`,
    codexBackendUrl: `${originUrl}/backend-api/codex`,
    codexChatGPTBaseUrl: `${originUrl}/backend-api`,
  };
}
