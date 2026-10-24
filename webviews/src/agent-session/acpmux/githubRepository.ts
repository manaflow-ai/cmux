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
  if (!owner || !repo || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(owner) || !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repo)) {
    return undefined;
  }
  return `${owner}/${repo}`;
}
