export const CODEROUTER_ORGANIZATION_COOKIE =
  "cmux_coderouter_organization";

const ORGANIZATION_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365;

export function coderouterOrganizationFromCookieHeader(
  cookieHeader: string | null,
  userId: string,
): string | null {
  if (!cookieHeader) return null;
  for (const part of cookieHeader.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (name !== CODEROUTER_ORGANIZATION_COOKIE) continue;
    try {
      const value: unknown = JSON.parse(
        decodeURIComponent(part.slice(separator + 1).trim()),
      );
      if (
        !Array.isArray(value) ||
        value.length !== 2 ||
        value[0] !== userId ||
        typeof value[1] !== "string"
      ) return null;
      return validOrganizationId(value[1]) ? value[1] : null;
    } catch {
      return null;
    }
  }
  return null;
}

export function persistCoderouterOrganizationScope(
  userId: string,
  organizationId: string,
): void {
  const cookie = coderouterOrganizationCookie(userId, organizationId);
  if (typeof document === "undefined" || !cookie) return;
  document.cookie = cookie;
}

export function coderouterOrganizationCookie(
  userId: string,
  organizationId: string,
): string | null {
  if (!validOrganizationId(userId) || !validOrganizationId(organizationId)) {
    return null;
  }
  return `${
    CODEROUTER_ORGANIZATION_COOKIE
  }=${encodeURIComponent(JSON.stringify([userId, organizationId]))}; Path=/; Max-Age=${
    ORGANIZATION_COOKIE_MAX_AGE_SECONDS
  }; SameSite=Lax; Secure`;
}

export function clearCoderouterOrganizationScope(): void {
  if (typeof document === "undefined") return;
  document.cookie = `${
    CODEROUTER_ORGANIZATION_COOKIE
  }=; Path=/; Max-Age=0; SameSite=Lax; Secure`;
}

function validOrganizationId(value: string): boolean {
  return value.length > 0 && value.length <= 200 && value === value.trim();
}
