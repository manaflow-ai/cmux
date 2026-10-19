import type { ProviderCapabilities } from "../capabilities.ts";

/** E2B's current platform limits and feature surface, verified against its public docs. */
export const E2B_CAPABILITIES: ProviderCapabilities = {
  provider: "e2b",
  pauseWithMemory: true, // https://docs.e2b.dev/sandbox/persistence
  stop: "none", // https://docs.e2b.dev/sandbox/persistence (E2B exposes pause/resume and kill, not stop)
  snapshotRunning: true, // https://docs.e2b.dev/sandbox/snapshots
  fork: "native", // https://docs.e2b.dev/api-reference/sandboxes/fork-sandbox.md
  resize: "none", // https://docs.e2b.dev/billing (resources are template/project limits)
  ssh: "websocket-proxy", // https://docs.e2b.dev/sandbox/ssh-access
  delegatedAccess: false, // https://docs.e2b.dev/sandbox/secured-access (envd credentials are cmux-held sandbox credentials)
  publicPorts: true, // https://docs.e2b.dev/network/public-url
  egressControl: "allow-deny-list", // https://docs.e2b.dev/network/internet-access
  volumes: true, // https://docs.e2b.dev/volumes (private beta, but supported by the provider)
  lifecycleEvents: "webhooks", // https://docs.e2b.dev/sandbox/lifecycle-events-webhooks
  maxVcpus: 8, // https://docs.e2b.dev/billing (Hobby plan maximum; larger Enterprise limits are account-specific)
  maxMemoryMib: 8192, // https://docs.e2b.dev/billing (Hobby plan maximum; larger Enterprise limits are account-specific)
  maxDiskMib: 20480, // https://docs.e2b.dev/billing (Pro plan documents 20 GiB; Enterprise is account-specific)
};
