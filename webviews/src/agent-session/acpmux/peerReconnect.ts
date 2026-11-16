import type { Translate } from "./i18n";
import type { PeerLinkDetail } from "./linkState";

export type PeerReconnect = { machine: string; since?: number };

/// Presentation of an outage the daemon has already detected. A delayed ping (degraded), initial
/// connection, paused machine, sign-in refusal and required update each keep their own meaning.
export function peerReconnect(
  machine: string | undefined,
  detail?: PeerLinkDetail,
  state?: string,
): PeerReconnect | undefined {
  if (!machine) return undefined;
  const link = detail?.link ?? state;
  if (link !== "reconnecting" && link !== "restarting" && link !== "offline") return undefined;
  return { machine, since: detail?.downSince ?? detail?.since };
}

/// The daemon owns the outage start; retry state transitions never restart this elapsed label.
export function peerReconnectText(progress: PeerReconnect, now: number, t: Translate): string {
  return progress.since === undefined
    ? t("host.reconnectingTo", { machine: progress.machine })
    : t("host.reconnectingToTimed", {
        machine: progress.machine,
        seconds: Math.max(0, Math.floor((now - progress.since) / 1000)),
      });
}
