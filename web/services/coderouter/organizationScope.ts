export const CODEROUTER_ORGANIZATION_COOKIE =
  "cmux_coderouter_organization";

const ORGANIZATION_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365;

export function coderouterOrganizationFromCookieHeader(
  cookieHeader: string | null,
): string | null {
  if (!cookieHeader) return null;
  for (const part of cookieHeader.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (name !== CODEROUTER_ORGANIZATION_COOKIE) continue;
    try {
      const value = decodeURIComponent(part.slice(separator + 1).trim());
      return validOrganizationId(value) ? value : null;
    } catch {
      return null;
    }
  }
  return null;
}

export function persistCoderouterOrganizationScope(
  organizationId: string,
): void {
  const cookie = coderouterOrganizationCookie(organizationId);
  if (typeof document === "undefined" || !cookie) return;
  document.cookie = cookie;
}

export function coderouterOrganizationCookie(
  organizationId: string,
): string | null {
  if (!validOrganizationId(organizationId)) return null;
  return `${
    CODEROUTER_ORGANIZATION_COOKIE
  }=${encodeURIComponent(organizationId)}; Path=/; Max-Age=${
    ORGANIZATION_COOKIE_MAX_AGE_SECONDS
  }; SameSite=Lax; Secure`;
}

function validOrganizationId(value: string): boolean {
  return value.length > 0 && value.length <= 200 && value === value.trim();
}
