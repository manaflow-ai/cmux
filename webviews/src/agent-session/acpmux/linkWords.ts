import type { Translate } from "./i18n";
import type { PeerLink } from "./peerLink";

/// acpmux's peer link state in the sidebar machine header's words ("Reconnecting…", "Offline"), or what
/// is wrong when acpmux knows (a refused sign-in, an update, this Mac's own network).
export function linkWords(link: PeerLink, t: Translate): string {
  if (link.why) return t(`machineLink.${link.why}`);
  switch (link.link) {
    case "connected":
      return t("machineLink.connected");
    case "connecting":
      return t(link.reconnecting ? "machineLink.reconnecting" : "machineLink.connecting");
    case "offline":
      return t("machineLink.offline");
  }
}
