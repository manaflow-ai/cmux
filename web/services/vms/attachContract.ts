import { CMUX_TUI_SESSION } from "./drivers/cmuxTuiDaemon";
import { freestyleCmuxRemoteRoute } from "./drivers/freestyle";
import type { VmImageManifestEntry } from "./images/resolver";

/** The authenticated, dial-ready part of a snapshot-v2 create receipt. */
export type VmAttachBlock = {
  readonly transport: "cmux-remote";
  readonly route: string;
  /** Trusted-carrier listeners authenticate by the carrier marker, so no bearer token is needed. */
  readonly token: string;
  readonly session: string;
  readonly trustedCarrier: boolean;
  readonly daemonBuild: {
    readonly commit: string | null;
    readonly remoteProtocol: null;
    readonly version: null;
  };
  readonly guestToolsBaked: boolean;
  readonly readiness: "dial";
};

export type VmAttachEntry = {
  readonly addressIpv4: string | null;
  readonly addressIpv6: string | null;
  readonly cmuxTuiContract: string | null;
  readonly providerVmId?: string;
};

/** Builds a dialable receipt without another provider or control-plane call. */
export function createAttachBlock(input: {
  readonly entry: VmAttachEntry;
  readonly manifestEntry: VmImageManifestEntry | null;
}): VmAttachBlock | null {
  const { entry, manifestEntry } = input;
  const ipv4 = entry.addressIpv4?.trim() || undefined;
  const ipv6 = entry.addressIpv6?.trim() || undefined;
  if (!manifestEntry || entry.cmuxTuiContract !== "snapshot-v2" || (!ipv4 && !ipv6)) return null;
  return {
    transport: "cmux-remote",
    route: freestyleCmuxRemoteRoute({ vpcs: [{ ipv4, ipv6 }] }, entry.providerVmId ?? "unknown"),
    token: "",
    session: CMUX_TUI_SESSION,
    trustedCarrier: true,
    daemonBuild: { commit: manifestEntry.cmuxdRemoteCommit ?? null, remoteProtocol: null, version: null },
    guestToolsBaked: true,
    readiness: "dial",
  };
}
