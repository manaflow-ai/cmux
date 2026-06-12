// Timeline row components for the /agent-chat surface, one renderer per
// `ItemType` family. Expand/collapse is plain per-row component state; markdown
// goes through the shared sanitizing renderer from the agent-session surface.
// Tool-shaped items route through the rich renderers in toolRows.tsx (diffs,
// structured command output, file previews, search results).

import { useState } from "react";
import { renderMarkdownHTML } from "../../agent-session/shared/markdown";
import { agentChatLabels } from "../labels";
import type { PendingRequest } from "../conversationStore";
import type { ConversationItem } from "../protocol";
import { isToolItemType } from "./display";
import { RichToolRow, StatusIndicator, rowDataProps } from "./toolRows";

export function ItemRow({ item }: { item: ConversationItem }) {
  if (item.type === "user_message") {
    return <UserMessageRow item={item} />;
  }
  if (item.type === "assistant_message") {
    return <AssistantMessageRow item={item} />;
  }
  if (item.type === "reasoning") {
    return <ReasoningRow item={item} />;
  }
  if (item.type === "plan") {
    return <PlanRow item={item} />;
  }
  if (isToolItemType(item.type)) {
    return <RichToolRow item={item} />;
  }
  return <SystemRow item={item} />;
}

function UserMessageRow({ item }: { item: ConversationItem }) {
  return (
    <div className="agent-chat-row agent-chat-user-row" {...rowDataProps(item)}>
      <div className="agent-chat-user-bubble">{item.text ?? ""}</div>
    </div>
  );
}

function AssistantMessageRow({ item }: { item: ConversationItem }) {
  return (
    <div className="agent-chat-row agent-chat-assistant-row" {...rowDataProps(item)}>
      <div
        className="agent-chat-markdown"
        // renderMarkdownHTML sanitizes its output (script/iframe/style and
        // event handlers stripped, URLs restricted to http/https/mailto).
        dangerouslySetInnerHTML={{ __html: renderMarkdownHTML(item.text ?? "") }}
      />
      {item.status !== "completed" ? <StatusIndicator status={item.status} /> : null}
    </div>
  );
}

function ReasoningRow({ item }: { item: ConversationItem }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="agent-chat-row agent-chat-reasoning-row" {...rowDataProps(item)}>
      <button
        type="button"
        className="agent-chat-disclosure"
        aria-expanded={expanded}
        onClick={() => setExpanded((current) => !current)}
      >
        <span className="agent-chat-disclosure-chevron" aria-hidden="true">
          {expanded ? "▾" : "▸"}
        </span>
        <span className="agent-chat-reasoning-label">{agentChatLabels.reasoning}</span>
        {item.status !== "completed" ? <StatusIndicator status={item.status} /> : null}
      </button>
      {expanded ? (
        <div
          className="agent-chat-markdown agent-chat-reasoning-body"
          dangerouslySetInnerHTML={{ __html: renderMarkdownHTML(item.text ?? "") }}
        />
      ) : null}
    </div>
  );
}

function PlanRow({ item }: { item: ConversationItem }) {
  return (
    <div className="agent-chat-row agent-chat-plan-row" {...rowDataProps(item)}>
      <div className="agent-chat-plan-header">
        <span className="agent-chat-badge">{agentChatLabels.plan}</span>
        {item.status !== "completed" ? <StatusIndicator status={item.status} /> : null}
      </div>
      <div
        className="agent-chat-markdown"
        dangerouslySetInnerHTML={{ __html: renderMarkdownHTML(item.text ?? "") }}
      />
    </div>
  );
}

function SystemRow({ item }: { item: ConversationItem }) {
  const label =
    item.type === "context_compaction"
      ? agentChatLabels.contextCompacted
      : item.type === "error"
        ? agentChatLabels.errorRow
        : item.type === "interrupted"
          ? agentChatLabels.stoppedRow
          : agentChatLabels.eventRow;
  return (
    <div
      className={`agent-chat-row agent-chat-system-row${item.type === "error" ? " is-error" : ""}`}
      {...rowDataProps(item)}
    >
      <span className="agent-chat-system-label">{label}</span>
      {item.text ? <span className="agent-chat-system-text">{item.text}</span> : null}
    </div>
  );
}

export function TurnSeparator() {
  return <div className="agent-chat-turn-separator" aria-hidden="true" />;
}

/**
 * Prominent banner shown while the agent is blocked on the user (P1: display
 * only, no answer buttons yet).
 */
export function PendingRequestBanner({ request }: { request: PendingRequest }) {
  const label =
    request.request_type === "user_input"
      ? agentChatLabels.waitingForInput
      : request.request_type === "tool_approval"
        ? agentChatLabels.waitingForPermission
        : agentChatLabels.waiting;
  return (
    <output
      className="agent-chat-request-banner"
      data-request-id={request.id}
      data-request-type={request.request_type}
    >
      <span className="agent-chat-request-banner-label">{label}</span>
      {request.detail ? (
        <span className="agent-chat-request-banner-detail">: {request.detail}</span>
      ) : null}
    </output>
  );
}
