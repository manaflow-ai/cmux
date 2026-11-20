// A link in a pull request's body or comment: it opens through the host only when it is https, on
// the person's click (GitHubMarkdown.tsx and githubHTML.tsx draw them).
import type { ReactNode } from "react";

export type Open = (url: string) => void;

/** `href` when the page may open it: an absolute https link. */
export function openableLink(href: string): string | undefined {
  try {
    const url = new URL(href);
    return url.protocol === "https:" ? url.href : undefined;
  } catch {
    return undefined;
  }
}

export function Link({ href, open, children }: { href: string; open: Open; children: ReactNode }) {
  const url = openableLink(href);
  if (!url) return <span className="gh-md-link">{children}</span>;
  return (
    <a
      className="gh-md-link"
      href={url}
      title={url}
      onClick={(event) => {
        event.preventDefault();
        open(url);
      }}
    >
      {children}
    </a>
  );
}
