/**
 * The one rule for deleting a provider tunnel that was found rather than recorded (by its slug, or in a listing): it is
 * attached to exactly one network, and that network is the mesh's. A device create sends exactly one network (the
 * mesh's), and nothing attaches more to a device tunnel, so anything else is not provably this mesh's device tunnel:
 * no attachments, a missing network id, a second attachment, or another network. Every path that deletes such a tunnel
 * checks this first and deletes nothing when it fails: `findDeviceTunnel` (src/upstream/live-mesh.ts), which the revoke
 * and an enroll's reconcile delete through, and the tunnel orphan sweep (src/upstream/orphan-sweep.ts).
 */
export interface TunnelAttachmentLike {
  readonly vpcId?: string | null | undefined;
}

export const attachedOnlyTo = (attachments: ReadonlyArray<TunnelAttachmentLike> | null | undefined, network: string): boolean =>
  attachments !== null && attachments !== undefined && attachments.length === 1 && network.length > 0 && attachments[0]?.vpcId === network;
