import { stackApiBaseURL } from "../stackApiBaseURL";

/**
 * Everything a browser-facing Hexclave call needs. The publishable client key
 * is public by design: it identifies the project to the client API and carries
 * no authority beyond what an end user already has.
 */
export type HexclaveClientConfig = {
  /** API origin with no trailing slash, e.g. `https://api.stack-auth.com`. */
  readonly apiBaseURL: string;
  readonly projectId: string;
  readonly publishableClientKey: string;
};

export function hexclaveClientConfig(): HexclaveClientConfig | null {
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim();
  const publishableClientKey =
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY?.trim();
  if (!projectId || !publishableClientKey) return null;
  return {
    apiBaseURL: stackApiBaseURL(),
    projectId,
    publishableClientKey,
  };
}

export function requireHexclaveClientConfig(): HexclaveClientConfig {
  const config = hexclaveClientConfig();
  if (!config) throw new Error("Hexclave auth is not configured");
  return config;
}

/** REST prefix every client endpoint sits behind. */
export const HEXCLAVE_API_VERSION_PATH = "/api/v1";
