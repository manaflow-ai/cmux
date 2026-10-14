// The composer strip (hq#1957, Leo and Lawrence 2026-10-14): the items after the folder and
// machine in the strip on the composer card's top edge (ComposerContext.tsx): the chat's pull
// requests, then its running subagents. Lower-priority items collapse first when the strip runs
// out of room (stripWidth.ts). How the strip meets the card is the variant's
// (composerStrip.experiment.ts, composerStrip.css): `flat`, `tab`, `gooey` or `tray`; `off` keeps
// the location strip and the pull request dock above it (DockedPullRequests).
import "./composerStrip.css";
import { useMemo, useRef } from "react";
import type { AcpmuxSnapshot } from "../model";
import { useChatPullRequests } from "../summary/pullRequests";
import { PullRequestDock } from "../summary/PullRequestDock";
import { pendingToolCalls, waitingSubagents } from "../summary/SubagentStatusList";
import { subagentsIn } from "../subagents/subagentRows";
import type { ComposerStripVariant } from "./composerStrip.experiment";
import { StripPullRequests } from "./StripPullRequests";
import { StripSubagents } from "./StripSubagents";
import { useStripSubagents } from "./subagentPresence";
import { useStripLayout } from "./stripWidth";
import { useComposerStripVariant } from "./stripVariant";

/// Mount keyed by the chat: the pull requests dismissed belong to one chat.
export function ComposerStrip({
  snapshot,
  sessionId,
  variant,
  onSubagent,
}: {
  snapshot: AcpmuxSnapshot;
  sessionId?: string;
  variant: ComposerStripVariant;
  onSubagent?: (id: string) => void;
}) {
  const { prs, dismiss } = useChatPullRequests(snapshot.rows, sessionId);
  const agents = useMemo(
    () => [...subagentsIn(snapshot.rows, snapshot.subagentViews).values()],
    [snapshot.rows, snapshot.subagentViews],
  );
  const waiting = useMemo(
    () => waitingSubagents(pendingToolCalls(snapshot), snapshot.subagentViews),
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the asks' inputs, not the whole snapshot
    [snapshot.rows, snapshot.permission, snapshot.permissionGroups, snapshot.subagentViews],
  );
  const entries = useStripSubagents(agents, waiting);
  const items = useRef<HTMLSpanElement>(null);
  const key = [...prs.map((pr) => pr.url), "|", ...entries.map((entry) => `${entry.agent.id}:${entry.status}`)].join(
    ",",
  );
  const level = useStripLayout(items, variant, key);
  return (
    <span ref={items} className="acpmux-strip-items" data-empty={prs.length + entries.length === 0 ? "" : undefined}>
      <StripPullRequests prs={prs} compact={level >= 2} onDismiss={dismiss} />
      <StripSubagents entries={entries} collapsed={level >= 1} onOpen={onSubagent} />
    </span>
  );
}

/// The pull request dock above the composer, drawn only while the strip variant is `off` (the
/// strip holds the pull requests otherwise).
export function DockedPullRequests(props: React.ComponentProps<typeof PullRequestDock>) {
  return useComposerStripVariant() === "off" ? <PullRequestDock {...props} /> : null;
}
