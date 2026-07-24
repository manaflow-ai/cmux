type PortalUser = {
  readonly isAnonymous: boolean;
};

export function canEnterCloudPortal(user: PortalUser | null): user is PortalUser {
  return user !== null && !user.isAnonymous;
}

export function resolveHomePortalPaths(portal?: string[]): {
  initialPath: string;
  returnPath: string;
} {
  const returnPath = portal?.length
    ? `/home/${portal.map(encodeURIComponent).join("/")}`
    : "/home";
  const initialPath = portal?.[0] === "activity"
    ? "/activity"
    : portal?.[0] === "machines" && portal[1]
      ? `/machines/${encodeURIComponent(portal[1])}`
      : "/";
  return { initialPath, returnPath };
}
