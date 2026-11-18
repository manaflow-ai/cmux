const GITHUB_REF = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/(?:pull|issues)\/(\d+)\/?(?:[?#].*)?$/;

/// `owner/repo#N` for a GitHub pull request or issue address, else undefined.
export function githubRefLabel(href: string): string | undefined {
  const match = GITHUB_REF.exec(href);
  return match ? `${match[1]}#${match[2]}` : undefined;
}

/// A pull request's or issue's own title from GitHub's page title ("Fix the thing by leo ·
/// Pull Request #12 · owner/repo · GitHub") for its hover card, or undefined when cmux has no
/// title for it.
export function githubRefTitle(page: string | undefined): string | undefined {
  if (!page) return undefined;
  const title = page
    .split(" · ")[0]!
    .replace(/ by [\w-]+$/, "")
    .trim();
  return title && !/^(GitHub|Pull Request|Issue)\b/.test(title) ? title : undefined;
}
