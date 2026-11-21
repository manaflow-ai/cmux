// The chat pane's subagents, kept out of App: App is too large for the React Compiler, and these
// compile on their own. `useSubsessions`: the store the transcript's sub-session cards read
// (subsessions.ts). `useSubagentNavigation`: how the pane opens, shows and stops its subagents
// (subagentPanes.ts, subagentShown.ts, subagentEscape.ts).
import { useCallback, useInsertionEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { callNative } from "../callNative";
import type { AcpmuxDirectClient } from "../direct";
import type { Translate } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";
import { openOfferChat, openSenderChat } from "../rows/rowActions";
import { knownMark } from "../../shared/AgentMark";
import { workflowPaneRequest } from "../summary/workflowTranscript";
import { agentTone } from "./agentTones";
import { useSenderIconLook } from "./senderIconLook";
import type { Subagent } from "./subagentFold";
import {
  backToOpeningChat,
  showSubagent as showSubagentIn,
  subagentRowMark,
  subagentTabTitle,
  useAutoOpenSubagents,
  useOpenNewSubagents,
} from "./subagentPanes";
import { useEscapeClosesSubagent } from "./subagentEscape";
import { shownSubagentFacts, useShownSubagent } from "./subagentShown";
import { SubsessionStore, type Subsessions } from "./subsessions";

/// The transcript's sub-session cards read each sub-session's state from one store, so a session
/// changing never redraws a turn (subagents/subsessions.ts); a name opens its chat beside this one.
/// One store for the pane's life, and one value while `notices` is the same.
export function useSubsessions(
  sessions: readonly AcpmuxSessionEntry[],
  notices: { senderMissing?: (name: string) => void },
): Subsessions {
  const [store] = useState(() => new SubsessionStore());
  useLayoutEffect(() => {
    store.set(sessions);
  }, [store, sessions]);
  return useMemo<Subsessions>(
    () => ({
      store,
      open: openOfferChat,
      openSender: openSenderChat,
      // A sender chip whose name acpmux resolves to no chat says so, in a toast.
      senderMissing: notices.senderMissing,
    }),
    [store, notices],
  );
}

export type SubagentNavigationInput = {
  snapshot: Pick<AcpmuxSnapshot, "rows" | "subagentViews" | "clockOffsetMs" | "summary">;
  t: Translate;
  chatName: string;
  shownSessionId: string | undefined;
  quick: boolean;
  /// The chat's subagents as its rows hold them now (subagentRows.ts `subagentsIn`).
  freshAgents: readonly Subagent[];
  /// The shown subagent from its own records, when the chat's rows no longer hold it (subagentOwnLog.ts).
  ownLoggedAgent: Subagent | undefined;
  subagentView: string | undefined;
  setSubagentView: (id: string | undefined) => void;
  ownSubagentPane: boolean;
  /// This pane was opened on a subagent: read when a callback runs.
  subagentPaneRef: { readonly current: boolean };
  /// `subagentPaneRef` as of this render.
  inSubagentPane: boolean;
  directClientRef: { readonly current: AcpmuxDirectClient | undefined };
  /// Ctrl-B moves work in this chat (conversation/runInBackground.ts `backgroundsWork`).
  canBackground: boolean;
};

export function useSubagentNavigation({
  snapshot,
  t,
  chatName,
  shownSessionId,
  quick,
  freshAgents,
  ownLoggedAgent,
  subagentView,
  setSubagentView,
  ownSubagentPane,
  subagentPaneRef,
  inSubagentPane,
  directClientRef,
  canBackground,
}: SubagentNavigationInput) {
  /// The name a subagent's pane tab shows (subagentPanes.ts subagentTabTitle): its own, else "Subagent of" the chat.
  const subagentTitle = (id: string) =>
    subagentTabTitle(
      freshAgents.find((agent) => agent.id === id),
      `${t("subagents.of")} ${chatName}`,
    );
  // The mark its row draws, which its pane's tab draws too (subagentPanes.ts `subagentRowMark`).
  const senderBadge = useSenderIconLook().badge;
  const chatMark = knownMark(snapshot.summary?.harness, snapshot.summary?.family);
  const subagentMark = (id: string) =>
    subagentRowMark(
      freshAgents.find((agent) => agent.id === id),
      chatMark,
      senderBadge,
    );
  // For callbacks that keep one identity (showSubagent names a pane's tab and its icon with them).
  // Written after render, before any effect or event reads it: a write during render keeps the hook
  // out of the React Compiler.
  const subagentTitleRef = useRef({ title: subagentTitle, mark: subagentMark });
  useInsertionEffect(() => {
    subagentTitleRef.current = { title: subagentTitle, mark: subagentMark };
  });
  // Only Claude Code's agents and workflows stop on their own (acpmux `_acpmux/subagent_stop`, which
  // this acpmux serves where it moves work: a Claude Code chat whatever its harness is named).
  const stopsSubagents = canBackground;
  const stopSubagent = useMemo(
    () =>
      stopsSubagents
        ? (id: string) => directClientRef.current?.stopSubagent(id) ?? Promise.reject(new Error())
        : undefined,
    [stopsSubagents, directClientRef],
  );
  const [autoOpenSubagents, setAutoOpenSubagents] = useAutoOpenSubagents();
  /// Shows subagent `id`: a person's open in a pane of its own right of the chat, focused; a new
  /// subagent's own open (`focus` false) only while the summary card's switch is on
  /// (subagents/subagentPanes.ts).
  const showSubagent = useCallback(
    (id: string, focus?: boolean) =>
      void showSubagentIn(callNative, id, focus ?? true, {
        panes: autoOpenSubagents,
        inSubagentPane: subagentPaneRef.current,
        here: setSubagentView,
        title: subagentTitleRef.current.title(id),
        tone: workflowPaneRequest(id) ? undefined : agentTone(id),
        // Seed a new pane from this chat's kept tail before its own attach answers: carried on the
        // pane's request, so the host holds it before it decides how the pane opens (#36650).
        beforeOpen: () => directClientRef.current?.tailHandOver(),
        mark: workflowPaneRequest(id) ? undefined : subagentTitleRef.current.mark(id),
      }),
    [autoOpenSubagents, subagentPaneRef, setSubagentView, directClientRef],
  );
  /// Shows subagent `id`'s view in place, or the chat's (`undefined`). In a pane opened on a subagent
  /// (beside the chat that opened it), going to the chat goes back to that chat's own tab instead and
  /// closes this one, so the chat never shows twice (subagentPanes.ts backToOpeningChat); a pane no
  /// chat opened shows the chat in place.
  const navigateSubagent = useCallback(
    (id: string | undefined) => {
      if (id !== undefined || !subagentPaneRef.current) return setSubagentView(id);
      void backToOpeningChat(callNative).then((back) => {
        if (!back) setSubagentView(undefined);
      });
    },
    [subagentPaneRef, setSubagentView],
  );
  // Escape closes a subagent's view to the chat's, as its pill's × does (subagents/subagentEscape.ts).
  useEscapeClosesSubagent(!quick && !!subagentView, () => navigateSubagent(undefined));
  // A pane opened on a subagent shows the chat's other subagents in place, and its "Subagent of" pill goes
  // back to the chat: its tab's name follows what it shows (review of #28497 at 995299ff). Not before
  // the subagent it was opened on has shown, or the name the app gave the tab would flash away; and not
  // while this page has no rows for the subagent yet (they load after the pane opens), which would name
  // it "Subagent of" over the name the chat's page gave it.
  // A subagent the chat's rows no longer hold is known from its own records (subagentOwnLog.ts).
  const shownAgent = subagentView
    ? (freshAgents.find((agent) => agent.id === subagentView) ?? ownLoggedAgent)
    : undefined;
  const shownSubagentTitle =
    ownSubagentPane && subagentView && shownAgent
      ? subagentTabTitle(shownAgent, `${t("subagents.of")} ${chatName}`)
      : undefined;
  const shownFacts = useMemo(
    () => (shownAgent ? shownSubagentFacts(shownAgent, snapshot.clockOffsetMs ?? 0) : undefined),
    [shownAgent, snapshot.clockOffsetMs],
  );
  // Its tab's hover card and spinner say the subagent's own state, not its chat's.
  useShownSubagent(
    callNative,
    ownSubagentPane,
    subagentView,
    shownSubagentTitle,
    shownFacts,
    subagentRowMark(shownAgent, chatMark, senderBadge),
  );
  useOpenNewSubagents(
    quick || inSubagentPane ? undefined : shownSessionId,
    snapshot.rows,
    snapshot.subagentViews,
    autoOpenSubagents,
    (id) => showSubagent(id, false),
    snapshot.clockOffsetMs ?? 0,
  );
  return { stopSubagent, autoOpenSubagents, setAutoOpenSubagents, showSubagent, navigateSubagent };
}
