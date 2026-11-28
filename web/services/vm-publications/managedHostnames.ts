import { createHash } from "node:crypto";

export const ORGANIZATION_SLUG_MAX_LENGTH = 19;
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;

export function validOrganizationSlug(value: string): boolean {
  return value.length <= ORGANIZATION_SLUG_MAX_LENGTH && SLUG.test(value);
}

/** A stable default. The database, not a display name, owns the reservation. */
export function organizationSlugCandidate(name: string | undefined, scopeId: string, attempt: number): string {
  const base = (name ?? "org").normalize("NFKD").toLowerCase()
    .replace(/[\u0300-\u036f]/gu, "").replace(/[^a-z0-9]+/gu, "-")
    .slice(0, ORGANIZATION_SLUG_MAX_LENGTH).replace(/^-+|-+$/gu, "") || "org";
  if (attempt === 0) return base;
  const suffix = createHash("sha256").update(`${scopeId}:${attempt}`).digest("hex").slice(0, 6);
  return `${base.slice(0, ORGANIZATION_SLUG_MAX_LENGTH - 7).replace(/-$/u, "")}-${suffix}`;
}

export function managedPublicationHostname(vmSlug: string, orgSlug: string, port: number, zone: string): string {
  if (!SLUG.test(vmSlug) || !validOrganizationSlug(orgSlug)) {
    throw new Error("Invalid managed publication slug");
  }
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new Error("Invalid publication port");
  const label = `${vmSlug}--${orgSlug}--${port}`;
  if (label.length > 63 || `${label}.${zone}`.length > 253) throw new Error("Publication hostname is too long");
  return `${label}.${zone}`;
}

export function normalizePublicationEmail(value: string): string | null {
  const email = value.trim().toLowerCase();
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email) ? email : null;
}
