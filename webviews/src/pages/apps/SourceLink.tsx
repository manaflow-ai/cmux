// The listing's source repo. An app installed from git links its repo at the pinned commit
// (`github.com/OWNER/REPO[/PATH] @ abc1234`); any other app keeps the plain Repository link.
import type { Strings } from "../shared/i18n";
import type { AppGitSource } from "./types";

const TREE_PATH: Record<string, string> = {
  "github.com": "/tree/",
  "codeberg.org": "/tree/",
  "gitlab.com": "/-/tree/",
};

/** The pinned link's text and href, or undefined when the app has no https repo and commit. */
export function sourceLink(source: AppGitSource): { text: string; href: string } | undefined {
  const { repository, commit } = source;
  if (!repository?.startsWith("https://") || !commit || !/^[0-9a-f]{7,64}$/i.test(commit)) return undefined;
  const base = repository.replace(/\/+$/, "").replace(/\.git$/, "");
  let host: string;
  try {
    host = new URL(base).host.toLowerCase();
  } catch {
    return undefined;
  }
  const path = source.path?.replace(/^\/+|\/+$/g, "") ?? "";
  const shown = base.slice("https://".length) + (path ? `/${path}` : "");
  const tree = TREE_PATH[host];
  const hrefPath = path ? `/${path.split("/").map(encodeURIComponent).join("/")}` : "";
  const href = tree ? `${base}${tree}${commit}${hrefPath}` : base;
  return { text: `${shown} @ ${commit.slice(0, 7)}`, href };
}

export function SourceLink({ source, strings }: { source: AppGitSource; strings: Strings }) {
  const pinned = sourceLink(source);
  if (pinned) {
    return (
      <p className="apps-source">
        <span className="apps-muted">{strings.t("store.action.repository")}</span>{" "}
        <a
          className="apps-link selectable"
          href={pinned.href}
          target="_blank"
          rel="noreferrer"
          title={source.tag ? `${source.tag} (${source.commit})` : source.commit}
        >
          {pinned.text} ↗
        </a>
      </p>
    );
  }
  if (!source.repository?.startsWith("https://")) return null;
  return (
    <a className="apps-link" href={source.repository} target="_blank" rel="noreferrer">
      {strings.t("store.action.repository")} ↗
    </a>
  );
}
