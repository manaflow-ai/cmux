// The chat's pull requests above the composer (cx-ncc.81, Claude desktop's PR bars): each one a
// `gh pr create` in the chat opened (sessionSummary.ts), newest first, with its number, repository,
// title and state. The chat folder's pull request, which the header chip follows live, shows its
// live state and title. The newest two show and the rest wait behind Show more; a dismissed bar
// stays hidden for this chat (the page's storage, so a reload keeps it hidden).
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { Close } from "../conversation/icons";
import { useHeaderState } from "../header/headerState";
import { PULL_REQUEST_BADGES as BADGES, shownPullRequest as shown, useChatPullRequests } from "./pullRequests";

const SHOWN = 2;

/// Mount keyed by the chat: dismissals and Show more belong to one chat.
export function PullRequestDock({ rows, sessionId }: { rows: readonly AcpmuxRow[]; sessionId?: string }) {
  const t = useT();
  const { pullRequest: live } = useHeaderState();
  const { prs, dismiss: dismissUrl } = useChatPullRequests(rows, sessionId);
  const [expanded, setExpanded] = useState(false);
  const dock = useRef<HTMLElement>(null);
  // The place of the bar just dismissed: focus moves to the bar now there, or the composer.
  const [refocus, setRefocus] = useState<number>();
  useEffect(() => {
    if (refocus === undefined) return;
    setRefocus(undefined);
    const buttons = dock.current?.querySelectorAll<HTMLElement>(".acpmux-pr-dock__dismiss");
    const next = buttons?.[Math.min(refocus, buttons.length - 1)];
    (
      next ?? document.querySelector<HTMLElement>(".acpmux-composer [contenteditable], .acpmux-composer textarea")
    )?.focus();
  }, [refocus]);
  if (prs.length === 0) return null;
  const visible = expanded ? prs : prs.slice(0, SHOWN);
  const dismiss = (url: string, index: number) => {
    dismissUrl(url);
    setRefocus(index);
  };
  return (
    <section ref={dock} className="acpmux-pr-dock" aria-label={t("prDock.label")}>
      {visible.map((pr, index) => {
        const { state, title, labeled } = shown(pr, live);
        const badge = BADGES[state];
        return (
          <div key={pr.url} className="acpmux-pr-dock__row">
            <a className="acpmux-pr-dock__bar" href={pr.url} data-state={state} title={title || undefined}>
              <Icon name="git.pullrequest" size={13} />
              <span className="acpmux-pr-dock__number">#{pr.number}</span>
              <span className="acpmux-pr-dock__repo" title={pr.repo}>
                {pr.repo.split("/").pop()}
              </span>
              {title && <span className="acpmux-pr-dock__title">{title}</span>}
              {labeled && <span className="acpmux-pr-dock__state">{badge ? t(badge) : state}</span>}
            </a>
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact acpmux-pr-dock__dismiss"
              aria-label={t("prDock.dismiss", { number: pr.number })}
              title={t("prDock.dismiss", { number: pr.number })}
              onClick={() => dismiss(pr.url, index)}
            >
              <Close size={12} />
            </button>
          </div>
        );
      })}
      {prs.length > SHOWN && (
        <button
          type="button"
          className="acpmux-pr-dock__more"
          aria-expanded={expanded}
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? t("prDock.less") : t("prDock.more", { count: prs.length - SHOWN })}
        </button>
      )}
    </section>
  );
}
