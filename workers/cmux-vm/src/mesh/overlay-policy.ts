import type { DesiredOverlayRule, MeshProtocol } from "./acl.ts";

export interface OverlayIdentity {
  readonly deviceId: string;
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
}

interface Allow {
  readonly protocol: MeshProtocol | "any";
  readonly port?: number;
}

/** Projects only incident, directed edges. The caller supplies live identities. */
export const projectOverlayPeers = (subject: string, identities: ReadonlyArray<OverlayIdentity>, rules: ReadonlyArray<DesiredOverlayRule>) => {
  const byId = new Map(identities.map((identity) => [identity.deviceId, identity]));
  const peers = new Map<string, OverlayIdentity & { inbound: Allow[]; outbound: Allow[] }>();
  for (const rule of rules) {
    const direction = rule.sourceDeviceId === subject ? "outbound" : rule.destinationDeviceId === subject ? "inbound" : null;
    if (direction === null) continue;
    const peerId = direction === "outbound" ? rule.destinationDeviceId : rule.sourceDeviceId;
    if (peerId === subject) continue;
    const identity = byId.get(peerId);
    if (identity === undefined) continue;
    let peer = peers.get(peerId);
    if (peer === undefined) {
      peer = { ...identity, inbound: [], outbound: [] };
      peers.set(peerId, peer);
    }
    peer[direction].push(rule.protocol === null ? { protocol: "any" } : rule.port === null ? { protocol: rule.protocol } : { protocol: rule.protocol, port: rule.port });
  }
  return [...peers.values()].sort((a, b) => a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0);
};
