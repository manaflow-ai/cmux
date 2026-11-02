/**
 * Normalize a git remote to the GitHub repository identity used by project
 * grouping (`owner/name`). Hosts from older builds returned the complete
 * remote URL while newer hosts already return the short identity; accepting
 * both keeps the project picker from showing the same checkout twice.
 */
export function githubRepository(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  if (!text) return undefined;

  let path: string;
  const scp = text.match(/^git@github\.com:([^\s]+)$/i);
  if (scp) {
    path = scp[1]!;
  } else if (/^(?:https?|ssh|git):\/\//i.test(text)) {
    try {
      const url = new URL(text);
      // A remote can carry a user (`ssh://git@github.com/...`) and a port;
      // the host is still the source of truth. Do not fold another forge into
      // a GitHub project merely because its path looks like owner/name.
      if (!/^(?:www\.)?github\.com$/i.test(url.hostname)) return undefined;
      path = url.pathname;
    } catch {
      return undefined;
    }
  } else if (/^github\.com\//i.test(text)) {
    path = text.slice(text.indexOf("/") + 1);
  } else {
    path = text;
  }

  path = path.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "");
  const parts = path.split("/");
  if (parts.length !== 2) return undefined;
  const [owner, repo] = parts;
  // A name may start with `.`, `_` or `-` (`acme/.github`), as the native host accepts; `.` and `..` are paths.
  const valid = (part: string | undefined) => !!part && part !== "." && part !== ".." && /^[\w.-]+$/.test(part);
  if (!valid(owner) || !valid(repo)) {
    return undefined;
  }
  return `${owner}/${repo}`;
}
