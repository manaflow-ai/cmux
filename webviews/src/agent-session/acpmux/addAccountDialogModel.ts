/** The daemon's built-in routes (routes.rs `builtin_routes`, accounts.rs): `route/list` leaves them
 * out, and a route file of their id replaces them, so a new account never takes one. */
const BUILT_IN_IDS = ["cmux", "codex-login", "claude-login"];

/** A route id from a name: lowercase letters, digits and `-` (routes.rs), unique among `taken` and
 * the built-in routes. */
export function accountIdFor(name: string, fallback: string, existing: readonly string[]): string {
  const taken = [...existing, ...BUILT_IN_IDS];
  const slug = (text: string) =>
    text
      .normalize("NFKD")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 48);
  const base = slug(name) || slug(fallback) || "account";
  if (!taken.includes(base)) return base;
  for (let n = 2; ; n++) if (!taken.includes(`${base}-${n}`)) return `${base}-${n}`;
}
