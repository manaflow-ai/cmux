// Base class and types
export { Sandbox } from "./Sandbox.js";
export type {
  CreateTerminalOptions,
  ExecOptions,
  ExecResult,
  SandboxConfig,
  SandboxInfo,
} from "./types.js";

// Implementations
export {
  BubblewrapSandbox,
  type BubblewrapSandboxConfig,
} from "./BubblewrapSandbox.js";

// Typed sandboxd client
export { SandboxdClient, SandboxdClientError } from "./sandboxd-client.js";

// Sandboxd API types
export type {
  AwaitReadyRequest,
  AwaitReadyResponse,
  CreateSandboxRequest,
  EnvVar,
  ErrorBody,
  ExecRequest,
  ExecResponse,
  HealthResponse,
  NotificationLevel,
  NotificationLogEntry,
  NotificationRequest,
  PrunedItem,
  PruneRequest,
  PruneResponse,
  PtyCaptureResponse,
  PtyCreateSessionRequest,
  PtyResizeRequest,
  PtySession,
  SandboxDisplay,
  SandboxNetwork,
  SandboxStatus,
  SandboxSummary,
  ServiceReadiness,
} from "./sandboxd-types.js";
