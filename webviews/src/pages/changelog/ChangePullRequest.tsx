// A change's pull request as the agent pane's reference chip with its one link hover card (Leo
// 2026-10-21: "a PR chip with the shared hover card"): hovering the change's title or its `#N`
// shows the pull request's title, state, author, checks and files, with Open and Open in. The card
// is chips/LinkHoverCard.tsx as the transcript draws it; this page only routes its host calls to
// the changelog's owner (`routeChipHost`), installs its strings (paneStrings.ts) and maps the
// pane's colour tokens to the page theme (styles.css).
import { useState } from "react";
import { setChipHost } from "../../agent-session/acpmux/chips/host";
import { LinkHoverCard } from "../../agent-session/acpmux/chips/LinkHoverCard";
import { pullRequestRef } from "../../agent-session/acpmux/chips/PullRequestCard";
import { useHoverCard } from "../../agent-session/acpmux/chips/useHoverCard";
import { GitHubMark } from "../../agent-session/acpmux/conversation/icons";
import type { PageClient } from "../shared/pageClient";
import "./paneStrings";
import "../../agent-session/acpmux/chips/chips.css";
import "../../agent-session/acpmux/previewCard/previewCard.css";

const REPO = "manaflow-ai/cmux";

const pullURL = (pr: number) => `https://github.com/${REPO}/pull/${pr}`;

function pullRequest(urlOrNumber: number | string): { href: string; repo: string; number: number } | undefined {
  // Host-provided notes need the same runtime validation as the shared card, even when
  // they did not pass through the publishing schema. Numeric legacy references do too.
  const ref = pullRequestRef(typeof urlOrNumber === "number" ? pullURL(urlOrNumber) : urlOrNumber);
  return ref && { href: ref.url, repo: ref.repo, number: ref.number };
}

/// The card asks the host what it knows about the pull request (`pr.inspect`), which browsers it
/// can open in (`browser.list`) and to open it (`browser.openIn`). On this page those go to the
/// changelog's owner as `cmux.changelog.<method>`, through the page's own client: a second client
/// would take over the page's bridge. Without a host the card shows what the page knows.
export function routeChipHost(client: PageClient | null): void {
  setChipHost(client ? (method, params) => client.call(`cmux.changelog.${method}`, params) : undefined);
}

export function ChangePullRequest({ pr, title }: { pr: number | string; title: string }) {
  const ref = pullRequest(pr);
  if (!ref) return <span className="cl-change-link">{title}</span>;
  return <ValidChangePullRequest ref={ref} title={title} />;
}

function ValidChangePullRequest({
  ref,
  title,
}: {
  ref: { href: string; repo: string; number: number };
  title: string;
}) {
  const hover = useHoverCard();
  const [anchor, setAnchor] = useState<HTMLAnchorElement | null>(null);
  const href = ref.href;
  const mark = <GitHubMark size={13} className="cv-chip__icon cv-chip__icon--gh" />;
  return (
    <>
      {/* The title is a link too (Leo 2026-10-21: "more colored links? not just the #"). */}
      <a className="cl-change-link" href={href} rel="noreferrer" {...hover.trigger}>
        <span>{title}</span>
      </a>
      {/* The title already links the same pull request: one tab stop per change. */}
      <a
        ref={setAnchor}
        className="cl-pr cv-link cv-chip is-web is-ref"
        href={href}
        rel="noreferrer"
        tabIndex={-1}
        {...hover.trigger}
      >
        {mark}
        <span className="cv-chip__label">#{ref.number}</span>
      </a>
      <LinkHoverCard
        href={href}
        anchor={anchor}
        hover={hover}
        mark={mark}
        pullRequest={{ repo: ref.repo, number: ref.number, title }}
      />
    </>
  );
}
