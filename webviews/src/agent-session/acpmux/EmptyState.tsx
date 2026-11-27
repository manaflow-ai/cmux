import { useLayoutEffect, useRef } from "react";
import type { Project } from "./ProjectChooser";
import { NEW_CHAT_ENTRANCE, claimNewChatEntrance, playNewChatEntrance, type NewChatEntrance } from "./newChatEntrance";
import { TourOffer, type TourOfferActions } from "./repoTour/TourOffer";
/// A new chat's folder choices and what a pick does (cx-9g0w). The composer's folder chip draws them;
/// the chat view's empty state names no folder and asks nothing.
export type EmptyStateProjects = {
  projects: Project[];
  /// The chat's project folder; none in no project (the agent-home folder).
  current?: string;
  currentPeer?: string;
  /// The chat is in no project (its agent-home folder): No folder is checked.
  noProject?: boolean;
  onPick(cwd: string, peer?: string): void;
  onBrowse?(): void;
  onNoProject?(): void;
};

/// The chat view with no turns yet: the plain new chat, the one and only built-in. It is the same
/// screen on every path that reaches it (a new chat, a connect, a reconnect, a host error, a failed
/// start, a harness switch): nothing in the pane says "What should we build" or lists other chats
/// (Leo, 2026-11-22: "we wanted the plain one didnt we? without the chatter intro"). That builder
/// screen is an opt-in look in examples/looks/codex/send-parity, never a fallback here. With `tour`,
/// a folder no chat has used yet offers a repo tour (repoTour/TourOffer.tsx). On mount the tour offer
/// and the composer under it settle in on one spring (newChatEntrance.ts); `entrance` picks the motion.
/// `entranceKey` names the chat: its entrance plays once, and a remount of the same chat's empty state is at rest.
export function EmptyState({
  tour,
  entrance = NEW_CHAT_ENTRANCE,
  entranceKey,
}: {
  tour?: TourOfferActions;
  entrance?: NewChatEntrance;
  entranceKey?: string;
}) {
  const root = useRef<HTMLDivElement>(null);
  // The mount's entrance only: a tour offer that shows later joins an empty state already at rest.
  const entranceOnMount = useRef(entrance);
  const entranceKeyOnMount = useRef(entranceKey);
  useLayoutEffect(() => {
    if (!claimNewChatEntrance(entranceKeyOnMount.current)) return undefined;
    const play = playNewChatEntrance(root.current, entranceOnMount.current);
    return () => play?.stop();
  }, []);
  return (
    <div ref={root} className="acpmux-empty" data-plain-new-chat="">
      {tour && (
        <div className="acpmux-empty-title-anchor">
          <TourOffer {...tour} />
        </div>
      )}
    </div>
  );
}
