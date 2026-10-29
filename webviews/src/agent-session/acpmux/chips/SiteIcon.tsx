// A web link's site mark (T3 Code's inline favicons, drawn in cmux's own way): GitHub's and arXiv's
// marks for those sites, else the site's favicon once the host has it (siteIcons.ts), else the
// globe, which stays while the icon is asked for and when the site has none. The mark is a fixed
// square from its first frame, so an icon arriving later never widens the link and reflows the
// paragraph (Leo 2026-10-21, chips/LinkChips.tsx). A local or private address keeps the globe and
// is never asked about.
import { ArxivMark, GitHubMark, Globe } from "../conversation/icons";
import { siteIconHost, useSiteIcon } from "./siteIcons";

/// Which brand mark a site's links draw instead of a fetched favicon.
export function siteBrand(host: string | undefined): "github" | "arxiv" | undefined {
  if (!host) return undefined;
  if (host === "github.com" || host.endsWith(".github.com")) return "github";
  if (host === "arxiv.org" || host.endsWith(".arxiv.org")) return "arxiv";
  return undefined;
}

/// The mark before a web link's text. `known` is an icon cmux already holds for this very page
/// (`link.inspect`); it wins over the site's favicon.
export function SiteIcon({ href, known, size = "inline" }: { href: string; known?: string; size?: "inline" | "row" }) {
  const host = siteIconHost(href);
  const brand = siteBrand(host);
  // A brand mark needs no favicon: its site is never asked about.
  const fetched = useSiteIcon(brand ? undefined : host);
  const icon = brand ? undefined : (known ?? fetched);
  const px = size === "row" ? 16 : 14;
  return (
    <span className={`cv-chip__icon cv-site-icon cv-site-icon--${size}`} aria-hidden="true">
      {brand === "github" ? (
        <GitHubMark size={px - 1} />
      ) : brand === "arxiv" ? (
        <ArxivMark size={px} />
      ) : icon ? (
        // A background, not an <img>: copying a message copies its text, never the icons as images
        // the composer would attach (Lucas 2026-10-29).
        <span className="cv-site-icon__img" style={{ backgroundImage: `url("${icon}")` }} />
      ) : (
        <Globe size={px} strokeWidth={1.1} />
      )}
    </span>
  );
}
