// The share nudge (share/ShareNudge.tsx): one quiet line over the composer, once per install, that
// says a chat can be shared. It shows when a person's first chat on this Mac ends its first reply,
// and never again: not after its x, not after Share… or Invite people…, not once there is a second
// chat. Sharing is otherwise only in the chat's ••• menu (design chat-multiplayer.md, "Share
// dialog"), so a new person had no way to learn a chat can be shared.
//
// Once per install is the app's to keep, like a feature tip's (design feature-tips.md): the page
// claims the nudge (`tips.state {claim: "share-nudge"}`, the app's defaults) before the line draws,
// which the app grants only with no other tip in the last 14 days. The app checks the record and
// keeps it in one step, so two panes ending a turn at once never both show it. An app that keeps no records
// shows none, since a line that could not stay gone must not show at all. No timer, no observer:
// it reacts to the turn's end and to the person.
import { useEffect, useRef, useState } from "react";
import type { TipHost } from "../../../ui/featureTips/store";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";
import { turnEndedBetween } from "../snapshotCache";

/** The nudge's record id in the app's tip records (lower-case, digits and dashes). */
export const SHARE_NUDGE_ID = "share-nudge";

/** The person's own chats: not a side chat, nor one an agent or a Chief started, nor a lane
 *  another chat started (`reportsTo`, as leads.ts reads it). Archived chats count: a person who archived chats is not
 *  new here. */
export function ownChats(sessions: readonly AcpmuxSessionEntry[]): AcpmuxSessionEntry[] {
  return sessions.filter(
    (entry) =>
      !entry.side &&
      !entry.spawnedBy &&
      !entry.startedBy &&
      !(entry.reportsTo && entry.reportsTo !== entry.sessionId) &&
      !entry.chiefChild &&
      !entry.chiefTurn,
  );
}

/** The chat's first reply has just ended well: one ended turn, completed, with no error. Read up
 * to the second ended turn at most: a long chat's every row was filtered on each event. */
export function firstReplyCompleted(rows: readonly AcpmuxRow[]): boolean {
  let only: AcpmuxRow | undefined;
  for (const row of rows) {
    if (row.kind !== "turnSummary") continue;
    if (only) return false;
    only = row;
  }
  return only !== undefined && (only.status ?? "completed") === "completed" && !only.error && !only.failed;
}

/** What the nudge reads of the pane's snapshot (AcpmuxSnapshot). */
export type ShareNudgeChat = {
  sessionId?: string;
  origin?: AcpmuxSnapshot["origin"];
  peerCopy?: unknown;
  listedSessions?: true;
  sessions: readonly AcpmuxSessionEntry[];
  rows: readonly AcpmuxRow[];
  /** `watching`: a conversation another app runs that this chat only shows. */
  summary?: { peer?: string; hostKind?: string; watching?: string };
};

export type ShareNudgeContext = {
  /** The page runs in the app (the Share dialog and the share actions are the host's). */
  nativeHost: boolean;
  /** The Quick Composer panel: no chat header, no ••• menu. */
  quick: boolean;
  /** A subagent's own pane: its transcript is the subagent's, not a chat to share. */
  subagentPane: boolean;
  /** Settings > Show Feature Tips (`updates.showFeatureTips`). */
  tipsOn: boolean;
};

/** Why the nudge may not show for this chat now, or undefined when it may. Sharing is this Mac's
 *  own chats only: the app refuses another machine's chat before it mints the owner's token
 *  (AgentShareActions `notThisMac`), and a chat another app runs (`summary.watching`) is read-only here. */
export function shareNudgeBlocked(chat: ShareNudgeChat, context: ShareNudgeContext): string | undefined {
  if (!context.nativeHost) return "no-host";
  if (!context.tipsOn) return "tips-off";
  if (context.quick) return "quick";
  if (context.subagentPane) return "subagent";
  if (!chat.sessionId) return "no-chat";
  if (chat.origin !== "local") return "not-local";
  if (chat.summary?.watching) return "read-only";
  if (chat.peerCopy) return "peer";
  if (chat.summary?.peer || chat.summary?.hostKind === "cloud") return "peer";
  // Only a list read from the daemon says how many chats there are.
  if (!chat.listedSessions) return "unlisted";
  const own = ownChats(chat.sessions);
  if (own.length !== 1 || own[0]?.sessionId !== chat.sessionId) return "not-first-chat";
  const entry = own[0];
  if (entry?.peer || entry?.hostKind === "cloud") return "peer";
  if (!firstReplyCompleted(chat.rows)) return "not-first-reply";
  return undefined;
}

export type ShareNudgeState = {
  shown: boolean;
  /** Hides it for good: its x, Share… or Invite people… (the record was kept when it showed). */
  close(): void;
};

type Phase = "waiting" | "asking" | "shown" | "done";

/** The nudge's life in one page: it waits for a turn of this chat to end, and shows only when that
 *  end is the first chat's first reply and the app records it for the first time. It goes for good
 *  on its x or an action, when the next turn starts, the chat changes, a second chat appears or
 *  tips are turned off. */
export function useShareNudge(
  chat: ShareNudgeChat & { isWorking: boolean; turnsEnded?: number },
  context: ShareNudgeContext,
  host: TipHost,
): ShareNudgeState {
  const [phase, setPhase] = useState<Phase>("waiting");
  // The chat whose turn this page saw end, until its next turn starts: seen live only, so a chat
  // reopened after it answered shows nothing. Kept apart from the check, since the turn's footer
  // row may land a snapshot after the turn stops working.
  const [endedIn, setEndedIn] = useState<string | undefined>(undefined);
  const [shownIn, setShownIn] = useState<string | undefined>(undefined);
  const mounted = useRef(true);
  const last = useRef({ session: chat.sessionId, working: chat.isWorking, turnsEnded: chat.turnsEnded });
  const blocked = shareNudgeBlocked(chat, context);
  useEffect(() => {
    const next = { session: chat.sessionId, working: chat.isWorking, turnsEnded: chat.turnsEnded };
    const ended = turnEndedBetween(last.current, next);
    last.current = next;
    if (ended) setEndedIn(chat.sessionId);
    else if (chat.isWorking) setEndedIn(undefined);
  }, [chat.sessionId, chat.isWorking, chat.turnsEnded]);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const ready = phase === "waiting" && endedIn !== undefined && endedIn === chat.sessionId && !blocked;
  useEffect(() => {
    if (!ready) return;
    setPhase("asking");
    const session = chat.sessionId;
    void host
      .read()
      .then(async (state) => {
        if (state.records[SHARE_NUDGE_ID] !== undefined) return false;
        // The app's claim keeps it before it draws (a page that reloads, or another window, never
        // shows it again) and says no within 14 days of any other tip: it spends the one budget
        // the feature tips, the Cloud hint and the sidebar's card share.
        return host.claim(SHARE_NUDGE_ID, undefined);
      })
      .then(
        (show) => {
          if (!mounted.current) return;
          setShownIn(show ? session : undefined);
          setPhase(show ? "shown" : "done");
        },
        () => {
          if (mounted.current) setPhase("done");
        },
      );
  }, [ready, chat.sessionId, host]);
  // The moment passed: the person sent again, moved to another chat, made a second one, or
  // turned tips off.
  const stale =
    phase === "shown" &&
    (chat.isWorking ||
      chat.sessionId !== shownIn ||
      !context.tipsOn ||
      (chat.listedSessions === true && ownChats(chat.sessions).length > 1));
  useEffect(() => {
    if (stale) setPhase("done");
  }, [stale]);
  return {
    shown: phase === "shown" && !stale,
    close: () => setPhase("done"),
  };
}
