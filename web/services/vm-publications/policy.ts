export type VmPublicationAccessMode = "personal" | "team" | "public";

export type VmPublicationPolicy = {
  readonly ownerUserId: string;
  readonly accessMode: VmPublicationAccessMode;
  readonly teamId: string | null;
};

export type VmPublicationViewer = {
  readonly userId: string;
  readonly teamIds: readonly string[];
  /** Only emails verified by the identity provider, never caller input. */
  readonly verifiedEmails?: readonly string[];
};

/** Validate the only legal personal/team/public policy shapes. */
export function validVmPublicationPolicy(
  accessMode: VmPublicationAccessMode,
  teamId: string | null | undefined,
): { readonly accessMode: VmPublicationAccessMode; readonly teamId: string | null } | null {
  const normalizedTeamId = teamId?.trim() || null;
  if (accessMode === "team") {
    return normalizedTeamId ? { accessMode, teamId: normalizedTeamId } : null;
  }
  return normalizedTeamId === null ? { accessMode, teamId: null } : null;
}

/** Evaluate a publication against current identity/team membership. */
export function vmPublicationAllowsViewer(
  publication: VmPublicationPolicy,
  viewer: VmPublicationViewer | null,
  owningTeamId: string | null = null,
): boolean {
  if (publication.accessMode === "public") return true;
  if (!viewer) return false;
  if (publication.accessMode === "personal") {
    return viewer.userId === publication.ownerUserId &&
      (owningTeamId === null || viewer.teamIds.includes(owningTeamId));
  }
  return publication.teamId !== null && viewer.teamIds.includes(publication.teamId);
}

/** Personal billing scopes use the VM owner's user id, not a Stack team id. */
export function publicationOwningTeamId(vm: { readonly userId: string; readonly billingTeamId: string | null }): string | null {
  return vm.billingTeamId && vm.billingTeamId !== vm.userId ? vm.billingTeamId : null;
}

/** Only the owning account can mutate publication policy. */
export function vmPublicationCanManage(
  publication: Pick<VmPublicationPolicy, "ownerUserId">,
  viewerUserId: string,
): boolean {
  return publication.ownerUserId === viewerUserId;
}
