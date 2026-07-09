export type SignedInForwardUser = { isRestricted?: boolean };

export type ResolveSignedInForwardOptions = {
  pathSegments: string[];
  searchParams: Record<string, string | string[] | undefined>;
  requestHost: string | null;
  getUser: () => Promise<SignedInForwardUser | null>;
};

export async function resolveSignedInForwardTarget({
  pathSegments,
  searchParams,
  requestHost,
  getUser,
}: ResolveSignedInForwardOptions): Promise<string | null> {
  const normalizedPathSegments = pathSegments.filter((segment) => segment !== "");
  if (
    normalizedPathSegments.length !== 1 ||
    !["sign-in", "sign-up"].includes(normalizedPathSegments[0] ?? "")
  ) {
    return null;
  }

  const afterAuthReturnTo = searchParams.after_auth_return_to;
  if (typeof afterAuthReturnTo !== "string") return null;

  const target = parseAfterAuthReturnTo(afterAuthReturnTo, requestHost);
  if (!target) return null;
  if (target.pathname !== "/handler/after-sign-in") return null;
  if (!target.searchParams.has("native_app_return_to")) return null;

  try {
    const user = await getUser();
    if (!user || user.isRestricted === true) return null;
  } catch {
    return null;
  }

  return `${target.pathname}${target.search}`;
}

function parseAfterAuthReturnTo(value: string, requestHost: string | null): URL | null {
  if (value.startsWith("//")) return null;

  if (value.startsWith("/")) {
    return new URL(value, "https://cmux.local");
  }

  let target: URL;
  try {
    target = new URL(value);
  } catch {
    return null;
  }

  if (!requestHost) return null;
  if (target.host.toLowerCase() !== requestHost.toLowerCase()) return null;

  return target;
}
