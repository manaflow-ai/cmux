// The agent pane on the right of a Home chat (Swift `HomeAgentSidePane` and `HomeAgentPaneView`):
// a tab strip, one tab per opened agent, over the selected agent's chat with the composer the
// person shares with the Chief. The tabs and selection are `AgentPaneState` (agentModel.ts); a
// tab click or its close button asks the owner, which steps the state.
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../strings";
import { AgentChat } from "./AgentChat";
import type { AgentChatContent, AgentPaneState } from "./agentModel";
import "../cards.css";

export interface AgentSidePaneProps {
  pane: AgentPaneState;
  /** What `peer`'s tab shows now; absent while its chat is not loaded. */
  content(peer: string): AgentChatContent | undefined;
  strings: Strings;
  onSelect(peer: string): void;
  onClose(peer: string): void;
  /** Go to workspace on `peer`'s tab: the host reads where it runs now, then opens it. */
  onGoToWorkspace(peer: string): void;
  onSend(peer: string, text: string): void;
}

export function AgentSidePane({
  pane,
  content,
  strings,
  onSelect,
  onClose,
  onGoToWorkspace,
  onSend,
}: AgentSidePaneProps) {
  if (!pane.tabs.length) return null;
  const selected = pane.selected;
  const chat = selected ? (content(selected) ?? emptyChat(selected)) : undefined;
  return (
    <aside className="hm-agent-pane">
      <div className="hm-agent-pane__strip">
        {pane.tabs.map((peer) => (
          <div key={peer} className="hm-agent-pane__tab" data-selected={peer === selected ? "" : undefined}>
            <button
              type="button"
              aria-pressed={peer === selected}
              className="hm-agent-pane__tab-name"
              onClick={() => onSelect(peer)}
            >
              {content(peer)?.title ?? peer}
            </button>
            <button
              type="button"
              className="hm-agent-pane__tab-close"
              aria-label={strings.t("home.agentPane.closeTab")}
              onClick={() => onClose(peer)}
            >
              <Icon name="action.close" size={12} />
            </button>
          </div>
        ))}
      </div>
      {chat && selected && (
        <AgentChat
          // One chat per agent: a new agent starts with its own draft and folds.
          key={selected}
          content={chat}
          strings={strings}
          actions={{
            goToWorkspace: chat.workspaceLink ? () => onGoToWorkspace(selected) : undefined,
            sent: (text) => onSend(selected, text),
          }}
        />
      )}
    </aside>
  );
}

/** An agent whose chat is not loaded: its id, nothing else. */
function emptyChat(peer: string): AgentChatContent {
  return { peer, title: peer, status: "", task: "", workedFor: "", details: [], messages: [] };
}
