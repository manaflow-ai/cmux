/**
 * The name a machine's prompt shows (`cmux@<name>`): its display label as a
 * slug, else its generated slug. Every writer of /etc/cmux/vm-name uses this,
 * including the guest's periodic refresh, so they never undo each other.
 */
export function vmPromptName(row: {
  readonly slug: string | null;
  readonly displayName: string | null;
}): string {
  const slug = (value: string) => value.normalize("NFKD").toLowerCase()
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-").slice(0, 63).replace(/^-+|-+$/g, "");
  return slug(row.displayName ?? "") || slug(row.slug ?? "") || "cmux";
}
