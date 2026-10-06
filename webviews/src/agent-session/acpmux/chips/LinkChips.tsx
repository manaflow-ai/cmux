// Link and path chips in replies (decision D4): an icon, the name with a dotted underline, and
// the full address in the tooltip. A path chip opens through the host (`file.open`, which checks
// the pane's roots and spends a user gesture); a web chip is an ordinary link, which the host
// opens outside the pane after a real click.
import type { ReactNode } from "react";
import { callChipHost } from "./host";
import { FileDoc, Folder, Globe } from "../conversation/icons";
import { isDeniedPath, openTarget, pathName } from "./paths";

/// A path chip. `label` is the link's text, or the file name for a bare path. A denied path is
/// plain text.
export function PathChip({ path, label, written }: { path: string; label?: ReactNode; written?: string }) {
  const shown = label ?? pathName(path);
  if (isDeniedPath(path)) return <span className="cv-chip-plain">{written ?? path}</span>;
  const folder = path.endsWith("/");
  return (
    <button
      type="button"
      className="cv-chip is-path"
      title={path}
      data-path={path}
      onClick={() => void callChipHost("file.open", { path: path.replace(/\/+$/, "") || "/", where: openTarget(path) })}
    >
      {folder ? (
        <Folder size={15} className="cv-chip__icon" />
      ) : (
        <FileDoc size={15} className="cv-chip__icon" />
      )}
      <span className="cv-chip__label">{shown}</span>
    </button>
  );
}

/// A web chip: the site's mark (`icon`, a globe by default), the link text, the full URL in the
/// tooltip. The anchor keeps the host's link-click path (a real click opens it outside the pane).
export function UrlChip({ href, icon, children }: { href: string; icon?: ReactNode; children: ReactNode }) {
  return (
    <a className="cv-link cv-chip is-web" href={href} rel="noreferrer" title={href}>
      {icon ?? <Globe size={15} strokeWidth={1.1} className="cv-chip__icon" />}
      <span className="cv-chip__label">{children}</span>
    </a>
  );
}
