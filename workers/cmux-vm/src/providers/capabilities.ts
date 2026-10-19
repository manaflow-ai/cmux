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
