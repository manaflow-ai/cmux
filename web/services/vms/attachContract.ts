import { randomBytes } from "node:crypto";
import { CMUX_TUI_ROUTE_TOKEN_TTL_SECONDS, CMUX_TUI_SESSION } from "./drivers/cmuxTuiDaemon";
import { freestyleCmuxRemoteRoute } from "./drivers/freestyle";
import type { CmuxRemoteEndpoint } from "./drivers/types";
import {
  GUEST_TOOLS_BAKED_EPOCH,
  TRUSTED_CARRIER_EPOCH,
  imageEpochAtLeast,
  vmImageEntryEpoch,
  type VmImageManifestEntry,
} from "./images/resolver";

/**
 * What a client needs to dial a machine's daemon straight from the create
 * response, before any attach call: the transport and route, whether the
 * daemon's cloud listener grants carrier authentication, the daemon build the
 * image carries, and whether the guest tools are baked (no heal execs on
 * attach). `readiness` is always `"dial"`: the daemon may still be starting,
 * and the Noise handshake is the readiness proof.
 *
 * `attach-endpoint` keeps its own shape as the repair and reconnect path.
 */
export type VmAttachBlock = {
  readonly transport: "cmux-remote";
  readonly route: string;
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
  /** The epoch stamped on the row at create; null on older rows (the manifest entry answers then). */
  readonly imageEpoch?: string | null;
  readonly providerVmId?: string;
};

/**
 * The attach block for a created machine, derived from the row and the
 * checked-in manifest alone (no provider round trip). Null when the row holds
 * no private address (the daemon is unreachable by address) or the image is
 * not a manifest entry (nothing is known about its daemon).
 *
 * The route follows the driver's rule: IPv4 first because only the v4 path is
 * reliable over the WireGuard tunnel, `[ipv6]` bracketed otherwise.
 */
export function createAttachBlock(input: {
  readonly entry: VmAttachEntry;
  readonly manifestEntry: VmImageManifestEntry | null;
}): VmAttachBlock | null {
  const { entry, manifestEntry } = input;
  const ipv4 = entry.addressIpv4?.trim() || undefined;
  const ipv6 = entry.addressIpv6?.trim() || undefined;
  if (!manifestEntry || (!ipv4 && !ipv6)) return null;
  const epoch = entry.imageEpoch ?? vmImageEntryEpoch(manifestEntry);
  return {
    transport: "cmux-remote",
    route: freestyleCmuxRemoteRoute({ vpcs: [{ ipv4, ipv6 }] }, entry.providerVmId ?? "unknown"),
    session: CMUX_TUI_SESSION,
    trustedCarrier: imageEpochAtLeast(epoch, TRUSTED_CARRIER_EPOCH),
    daemonBuild: { commit: manifestEntry.cmuxTuiCommit ?? null, remoteProtocol: null, version: null },
    guestToolsBaked: imageEpochAtLeast(epoch, GUEST_TOOLS_BAKED_EPOCH),
    readiness: "dial",
  };
}

/**
 * A route token for the lease ledger. On a private machine it is never
 * dialed with (the daemon's Noise session is the gate); the lease it is
 * hashed into is what sign-out revocation finds.
 */
export function mintCmuxRemoteRouteToken(): string {
  return `cmux-route-${randomBytes(32).toString("hex")}`;
}

/**
 * The endpoint for a client that proved it can dial the daemon (the attach
 * route's `readiness: "client-proven"`): the shape the driver returns,
 * minted from the row and the manifest alone. Null when the attach block is
 * (no private address, or an image outside the manifest).
 */
export function clientProvenCmuxRemoteEndpoint(input: {
  readonly entry: VmAttachEntry;
  readonly manifestEntry: VmImageManifestEntry | null;
}): CmuxRemoteEndpoint | null {
  const attach = createAttachBlock(input);
  if (!attach) return null;
  const ipv4 = input.entry.addressIpv4?.trim() || undefined;
  const ipv6 = input.entry.addressIpv6?.trim() || undefined;
  return {
    transport: "cmux-remote",
    route: attach.route,
    token: mintCmuxRemoteRouteToken(),
    expiresAtUnix: Math.floor(Date.now() / 1000) + CMUX_TUI_ROUTE_TOKEN_TTL_SECONDS,
    session: attach.session,
    trustedCarrier: attach.trustedCarrier,
    daemonBuild: attach.daemonBuild,
    networkAddresses: { ...(ipv4 ? { ipv4 } : {}), ...(ipv6 ? { ipv6 } : {}) },
  };
}
