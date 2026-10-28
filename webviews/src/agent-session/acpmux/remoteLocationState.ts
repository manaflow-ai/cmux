/// The status acpmux reported for the remote machine in the composer's location strip.
export type RemoteLocationState = "connected" | "connecting" | "offline" | "unknown";

const CONNECTING_STATES = new Set(["connecting", "degraded"]);

/// Converts the peer fields from `_acpmux/status` without inferring a state that was not reported.
/// Older daemons have no `state`, so an explicit connected flag remains authoritative for them.
export function remoteLocationState(input: { connected?: boolean; state?: string }): RemoteLocationState {
  if (input.state === "connected" && input.connected !== false) return "connected";
  if (input.state && CONNECTING_STATES.has(input.state)) return "connecting";
  if (input.state === "offline" || input.state === "reconnecting" || input.connected === false) return "offline";
  if (input.state === undefined && input.connected === true) return "connected";
  return "unknown";
}
