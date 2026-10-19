/** Providers the cmux VM control plane can run sandboxes on. */
export type ProviderId = "freestyle" | "e2b" | "daytona";

/**
 * What a provider can do. The API refuses a call outside it with
 * 409 `capability_unsupported { capability, provider }`, never a silent emulation.
 */
export interface ProviderCapabilities {
  readonly provider: ProviderId;
  /** Pause keeps memory, and start resumes the same processes. */
  readonly pauseWithMemory: boolean;
  readonly stop: "native" | "guest-shutdown" | "none";
  readonly snapshotRunning: boolean;
  readonly fork: "native" | "snapshot-create" | "none";
  readonly resize: "up-only" | "any" | "none";
  readonly ssh: "identity-token" | "access-token" | "websocket-proxy" | "none";
  /** The provider can mint its own scoped token for one sandbox (delegated end-user access). */
  readonly delegatedAccess: boolean;
  readonly publicPorts: boolean;
  readonly egressControl: "rules" | "allow-deny-list" | "on-off" | "none";
  readonly volumes: boolean;
  readonly lifecycleEvents: "webhooks" | "reconcile";
  readonly maxVcpus: number;
  readonly maxMemoryMib: number;
  readonly maxDiskMib: number;
}

export const DAYTONA_CAPABILITIES: ProviderCapabilities = {
  provider: "daytona", // https://www.daytona.io/docs/en/sandboxes.md#create-sandboxes
  pauseWithMemory: false, // https://www.daytona.io/docs/en/sandboxes.md#pause--resume-sandboxes (the adapter uses the default container class)
  stop: "native", // https://www.daytona.io/docs/en/sandboxes.md#stop-sandboxes
  snapshotRunning: false, // https://www.daytona.io/docs/en/sandboxes.md#sandbox-lifecycle (container cold snapshots require the sandbox to be stopped)
  fork: "snapshot-create", // https://www.daytona.io/docs/en/sandboxes.md#fork-sandboxes (container fork is refused; snapshot then create is supported)
  resize: "up-only", // https://www.daytona.io/docs/en/sandboxes.md#resize-sandboxes (the adapter exposes the contract's grow-only operation)
  ssh: "access-token", // https://www.daytona.io/docs/en/ssh-access.md#access-via-token
  delegatedAccess: true, // https://www.daytona.io/docs/en/ssh-access.md#access-via-token
  publicPorts: true, // https://www.daytona.io/docs/en/sandboxes.md#preview-urls
  egressControl: "allow-deny-list", // https://www.daytona.io/docs/en/network-limits.md (CIDR/domain allowlists and block-all)
  volumes: true, // https://www.daytona.io/docs/en/volumes.md
  lifecycleEvents: "webhooks", // https://www.daytona.io/docs/en/webhooks.md#sandbox-events
  maxVcpus: 4, // https://www.daytona.io/docs/en/sandboxes.md#resources
  maxMemoryMib: 8192, // https://www.daytona.io/docs/en/sandboxes.md#resources
  maxDiskMib: 10240, // https://www.daytona.io/docs/en/sandboxes.md#resources
};
