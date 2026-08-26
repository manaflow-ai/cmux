// Shared cmuxd-remote wiring constants for every VM driver. Before this module each driver
// re-declared its own copies and they had already drifted (e2b lacked the RPC lease path,
// blaxel lacked the legacy PTY path); a provider swap must not depend on which copy a driver
// happened to inherit.

/** Port cmuxd-remote listens on inside every VM (`serve --ws --listen 0.0.0.0:7777`). */
export const CMUXD_WS_PORT = 7777;

// Lease file paths inside the VM. The daemon learns its PTY/RPC lease paths once, from the
// `--auth-lease-file` / `--rpc-auth-lease-file` flags it was started with, so these are
// per-daemon-process constants, not per-attachment: changing them requires restarting the
// daemon (see daemon/remote/cmd/cmuxd-remote/ws_pty.go). Drivers that start the daemon
// themselves pass these paths; drivers attaching to an existing daemon discover the real
// paths from the process table and fall back to these.
export const CMUXD_WS_PTY_LEASE_PATH = "/tmp/cmux/attach-pty-lease.json";
export const CMUXD_WS_LEGACY_PTY_LEASE_PATH = "/tmp/cmux/attach-lease.json";
export const CMUXD_WS_RPC_LEASE_PATH = "/tmp/cmux/attach-rpc-lease.json";
export const CMUXD_WS_RPC_CLIENT_PATH = "/tmp/cmux/attach-rpc-client.json";

/** One-use PTY leases are minted per attach and consumed on connect. */
export const CMUXD_WS_PTY_LEASE_TTL_SECONDS = 5 * 60;
/** Reusable RPC leases back browser-panel proxying; reused across attaches until near expiry. */
export const CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60;
/** An RPC lease this close to expiry is replaced instead of reused. */
export const CMUXD_WS_RPC_RENEW_BEFORE_SECONDS = 60;

/** Login shell wrapper baked into cmux VM images (`--shell` flag of cmuxd-remote). */
export const CMUX_CLOUD_SHELL_PATH = "/usr/local/bin/cmux-cloud-shell";

export const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
export const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;

export const HEALTH_CHECK_TIMEOUT_MS = 10_000;
export const HEALTH_RETRY_ATTEMPTS = 12;
export const HEALTH_RETRY_INTERVAL_MS = 1_000;

/**
 * Normalizes a caller-supplied exec timeout: invalid or non-positive values fall back to the
 * default, everything is floored to whole milliseconds and clamped to the shared maximum.
 */
export function clampExecTimeoutMs(
  timeoutMs: number | undefined,
  defaultMs: number = EXEC_DEFAULT_TIMEOUT_MS,
  maxMs: number = MAX_EXEC_TIMEOUT_MS,
): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return defaultMs;
  }
  return Math.min(Math.floor(timeoutMs), maxMs);
}
