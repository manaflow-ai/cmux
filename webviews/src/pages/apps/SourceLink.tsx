// The listing's source repo. An app installed from git links its repo at the pinned commit
// (`github.com/OWNER/REPO[/PATH] @ abc1234`); any other app keeps the plain Repository link.
import type { Strings } from "../shared/i18n";
import type { AppGitSource } from "./types";
import { sourceLink } from "./sourceLinkTarget";

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
