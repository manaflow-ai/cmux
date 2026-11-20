import React from "react";
import { type AcpmuxRow, type AcpmuxSnapshot } from "../model";
import type { MockScript } from "../mock";
import { type AcpmuxDebug } from "../debug";
import { type ComposerReadback } from "../composer/externalAttach";
import type { DictationUpdate } from "../dictationText";
import { type MeasurableRenderer } from "../rows/rowProps";

declare global {
  interface Window {
    cmuxAcpmuxBridge?: {
      receive(snapshot: AcpmuxSnapshot): void;
      /** Sets or toggles the inspector and returns its next visibility. */
      toggleInspector(open?: boolean): boolean;
      applyTheme(theme: Record<string, unknown>): void;
      applyCustomization(customization: {
        themeCSS?: string;
        registryJS?: string;
        layout?: Record<string, unknown>;
      }): void;
      /// An app action for the page (CmuxNextAgentPane AgentPaneView), such as "continueIn".
      command?(name: string, sessionId?: string): void;
      /// Copy Last Code Block (Opt-Cmd-;): the app reads the block and writes the pasteboard itself,
      /// since a script it runs here is no gesture the page's clipboard accepts.
      lastCodeBlock?(): string | null;
      /// What the composer holds (`chat.composer.get`, composer/externalAttach.ts): its text and chips.
      composerState?(): ComposerReadback | null;
      /// Copy Conversation as Markdown: read recorded history on this page's connection; the native
      /// palette action writes the role-headed, tool-folded text to the pasteboard.
      conversationMarkdown?(): Promise<string | null>;
      /// The app's shortcuts as the user bound them, keyed by action id (shortcuts.ts).
      applyShortcuts?(labels: Record<string, string>): void;
      /// Preview features on or off (Settings > Advanced > Labs, `labs.previewFeatures`, off by
      /// default): prompt surface labels and the read-only access preview.
      applyPreview?(on: boolean): void;
      /// The default-off live-tree status card (Settings > Advanced > Labs, `labs.liveTree`).
      applyLiveTree?(on: boolean): void;
      /// How a Cloud start goes (cloudStartProgress.ts `cloudStartPushed`): `{key, step?, machine?,
      /// size?, secrets?, network?}` for the start `cloud.startChat {key}` began.
      cloudStartProgress?(push: unknown): void;
      /// Experimental workflow summary/detail (Labs), separate from environment preview and off by default.
      applyWorkflowLabs?(on: boolean): void;
      /// The native Debug Settings baseline for the sidebar latest-reply preview.
      applySidebarPreviewVariant?(variant: unknown): void;
      /// Claude Code desktop's in-session status (the live plan card) on or off: the
      /// Debug Settings toggle `agent.sessionStatus`, off by default (sessionStatus.ts).
      applySessionStatus?(on: boolean): void;
      /// Settings > Advanced > Experiments: every `experiments.*` switch as one object
      /// (`{"glassToolbarGroups": true}`), each off by default (experiments/switches.ts).
      applyExperiments?(value: unknown): void;
      /// Session `sessionId`'s avatar was set or removed in some pane: ask for it again (agentAvatar.ts).
      agentAvatarChanged?(sessionId: string): void;
      /// Suggested tasks on or off (Settings > Suggest Follow-Up Tasks, on by default, or the Debug
      /// toggle `agent.suggestedTasks` forcing them on): an agent's offers draw as the suggested tasks
      /// card (offer/offersShown.ts).
      applySuggestedTasks?(on: boolean): void;
      /// Session Info's Remote Control switch, `{on}` or null (remoteControl.ts), on the legacy host.
      applyRemoteControl?(value: unknown): void;
      /// The app's notices about the chat's agent service (paneNoticeStore.ts), on the legacy host.
      applyPaneNotices?(value: unknown): void;
      applyHeaderState?(state: unknown): void;
      /// The pane's tab row the header's tools may sit in (header/tabRow.ts).
      applyTabRow?(row: unknown): void;
      /// Start Agent's floating chat (floatingState.ts, cx-b9qi).
      applyFloatingState?(state: unknown): void;
      /// The newest device chats for the New Tab cards (newtab/deviceChats.ts).
      applyDeviceChats?(chats: unknown): void;
      /// The newest recently closed items for the New Tab page (newtab/recentlyClosed.ts).
      applyRecentlyClosed?(items: unknown): void;
      /// What plays, for the New Tab page's player (newtab/nowPlaying.ts); null while nothing does.
      applyNowPlaying?(track: unknown): void;
      /// The app's read-aloud state (conversation/readAloud.ts): `{id}`, the message it reads or null.
      applyReadAloud?(state: unknown): void;
      /// The tabs agents marked as needing the person, for Needs you (needsYou/attentionTabs.ts).
      applyAttentionTabs?(tabs: unknown): void;
      /// The workspaces, panes and tabs a pasted cmux link names (chips/cmuxLinkPlaces.ts).
      applyLinkPlaces?(places: unknown): void;
      applyLinkPlacesChanged?(places: unknown): void;
      /// Scrolls to a turn a `cmux://session/<id>#turn-<turnId>` link names (links.ts), once its row
      /// renders; gives up quietly after a few seconds.
      revealTurn?(turnId: string): void;
      /// A dictation change from the host (CmuxNextAgentPane AgentPaneDictation), spliced at the prompt's cursor.
      dictation?(update: DictationUpdate): void;
      /// A design mode highlight from a browser pane (CmuxNextAgentPane AgentPaneDesignSelection):
      /// its chips join the composer and go with the next message (designSelection.ts).
      designSelection?(selection: unknown): void;
      /// `cmux app chat perf` (the app's `agent.chat.perf`, every build): frames, long tasks,
      /// layout shift and each arriving record's time to paint for `seconds` (chatPerfCapture.ts).
      perfCapture?(options: { seconds?: unknown }): Promise<Record<string, unknown>>;
    };
    cmuxAcpmuxRegistry?: {
      register(
        kind: string,
        renderer: MeasurableRenderer,
        options?: { measure?: (row: AcpmuxRow, width: number) => number },
      ): void;
      configure(options: Record<string, unknown>): void;
    };
    cmuxAcpmuxDebug?: AcpmuxDebug;
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    /// Mock mode only: a recorded turn the in-page daemon replays (webviews/scripts/agent-pane).
    cmuxAcpmuxMockScript?: MockScript;
    React?: typeof React;
  }
}
