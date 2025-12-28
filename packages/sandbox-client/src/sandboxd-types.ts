/**
 * TypeScript types for cmux-sandboxd HTTP API.
 * Generated from packages/sandbox/src/models.rs
 */

// =============================================================================
// Request/Response Types
// =============================================================================

export interface EnvVar {
  key: string;
  value: string;
}

export interface CreateSandboxRequest {
  name?: string;
  /** Host path mounted into /workspace inside the sandbox */
  workspace?: string;
  tab_id?: string;
  read_only_paths?: string[];
  tmpfs?: string[];
  env?: EnvVar[];
}

export type SandboxStatus =
  | "Creating"
  | "Running"
  | "Exited"
  | "Failed"
  | "Unknown";

export interface SandboxNetwork {
  host_interface: string;
  sandbox_interface: string;
  host_ip: string;
  sandbox_ip: string;
  cidr: number;
}

/** Display configuration for a sandbox's isolated X11/VNC stack and VS Code server. */
export interface SandboxDisplay {
  /** X11 display number (e.g., 10 for :10) */
  display_number: number;
  /** VNC port (5900 + display_number, e.g., 5910) */
  vnc_port: number;
  /** noVNC WebSocket port (always 39380 inside sandbox, accessed via subdomain routing) */
  novnc_port: number;
  /** Chrome DevTools Protocol port */
  cdp_port: number;
  /** cmux-code (VS Code) port (always 39378 inside sandbox, accessed via subdomain routing) */
  vscode_port: number;
  /** cmux-pty port (always 39383 inside sandbox, accessed via subdomain routing) */
  pty_port: number;
}

/** Readiness status for sandbox services. */
export interface ServiceReadiness {
  /** VNC/X11 display is ready */
  vnc: boolean;
  /** VS Code server is ready */
  vscode: boolean;
  /** PTY server is ready */
  pty: boolean;
}

/** Request to await service readiness */
export interface AwaitReadyRequest {
  /** Services to wait for (default: all configured services) */
  services?: string[];
  /** Timeout in milliseconds (default: 10000) */
  timeout_ms?: number;
}

/** Response from await-ready endpoint */
export interface AwaitReadyResponse {
  /** Whether all requested services are ready */
  ready: boolean;
  /** Current readiness status of each service */
  services: ServiceReadiness;
  /** Services that timed out (if any) */
  timed_out?: string[];
}

export interface SandboxSummary {
  id: string;
  index: number;
  name: string;
  created_at: string;
  workspace: string;
  status: SandboxStatus;
  network: SandboxNetwork;
  /** Display configuration for isolated X11/VNC desktop. */
  display?: SandboxDisplay;
  /** Correlation ID (tab_id) for matching placeholders to created sandboxes. */
  correlation_id?: string;
}

export interface ExecRequest {
  /** Command arguments executed via nsenter inside the sandbox */
  command: string[];
  workdir?: string;
  env?: EnvVar[];
}

export interface ExecResponse {
  exit_code: number;
  stdout: string;
  stderr: string;
}

export interface HealthResponse {
  status: string;
}

export type NotificationLevel = "info" | "warning" | "error";

export interface NotificationRequest {
  message: string;
  level?: NotificationLevel;
  sandbox_id?: string;
  tab_id?: string;
  pane_id?: string;
}

export interface NotificationLogEntry {
  id: string;
  message: string;
  level?: NotificationLevel;
  sandbox_id?: string;
  tab_id?: string;
  pane_id?: string;
  received_at: string;
}

export interface PruneRequest {
  /** Only prune directories older than this many seconds. */
  max_age_secs?: number;
  /** If true, prune all orphaned directories regardless of age. */
  all?: boolean;
  /** If true, only report what would be deleted without actually deleting. */
  dry_run?: boolean;
}

export interface PrunedItem {
  id: string;
  path: string;
  age_secs: number;
  size_bytes?: number;
}

export interface PruneResponse {
  deleted_count: number;
  failed_count: number;
  items: PrunedItem[];
  dry_run: boolean;
  bytes_freed?: number;
}

// =============================================================================
// PTY Session Types
// =============================================================================

export interface PtyCreateSessionRequest {
  name?: string;
  command?: string;
  args?: string[];
  cols?: number;
  rows?: number;
  cwd?: string;
  /** Environment variables as key-value object (cmux-pty uses HashMap<String, String>) */
  env?: Record<string, string>;
}

export interface PtySession {
  id: string;
  name?: string;
  command: string;
  args: string[];
  cols: number;
  rows: number;
  cwd: string;
  created_at: string;
  exited: boolean;
  exit_code?: number;
}

export interface PtyResizeRequest {
  cols: number;
  rows: number;
}

export interface PtyCaptureResponse {
  content: string;
  cursor_x: number;
  cursor_y: number;
}

// =============================================================================
// Error Types
// =============================================================================

export interface ErrorBody {
  error: string;
  details?: string;
}
