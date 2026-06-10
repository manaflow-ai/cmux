// Timeline row components for the /agent-chat surface, one renderer per
// `ItemType` family. Expand/collapse is plain per-row component state; markdown
// goes through the shared sanitizing renderer from the agent-session surface.

import { useState } from "react";
import { renderMarkdownHTML } from "../../agent-session/shared/markdown";
import type { PendingRequest } from "../conversationStore";
import type { ConversationItem } from "../protocol";
import {
  formatToolInput,
  isToolItemType,
  statusGlyph,
  toolItemTitle,
  toolTypeGlyph,
  toolTypeLabel,
} from "./display";

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
    return <ToolRow item={item} />;
  }
  return <SystemRow item={item} />;
}

function rowDataProps(item: ConversationItem) {
  return {
    "data-item-id": item.id,
    "data-item-type": item.type,
    "data-item-status": item.status,
  };
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
        <span className="agent-chat-reasoning-label">Reasoning</span>
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
        <span className="agent-chat-badge">Plan</span>
        {item.status !== "completed" ? <StatusIndicator status={item.status} /> : null}
      </div>
      <div
        className="agent-chat-markdown"
        dangerouslySetInnerHTML={{ __html: renderMarkdownHTML(item.text ?? "") }}
      />
    </div>
  );
}

function ToolRow({ item }: { item: ConversationItem }) {
  const [expanded, setExpanded] = useState(false);
  const input = formatToolInput(item.input);
  const outputText = item.output?.text ?? "";
  const imageCount = item.output?.image_ids?.length ?? 0;
  const failed = item.status === "failed" || item.output?.is_error === true;
  return (
    <div className="agent-chat-row agent-chat-tool-row" {...rowDataProps(item)}>
      <button
        type="button"
        className="agent-chat-disclosure agent-chat-tool-summary"
        aria-expanded={expanded}
        onClick={() => setExpanded((current) => !current)}
      >
        <StatusIndicator status={item.status} />
        <span className="agent-chat-badge agent-chat-tool-badge">
          <span aria-hidden="true">{toolTypeGlyph(item.type)}</span> {toolTypeLabel(item.type)}
        </span>
        <span className="agent-chat-tool-title">{toolItemTitle(item)}</span>
        <span className="agent-chat-disclosure-chevron" aria-hidden="true">
          {expanded ? "▾" : "▸"}
        </span>
      </button>
      {expanded ? (
        <div className="agent-chat-tool-detail">
          {input !== "" ? (
            <pre className="agent-chat-mono agent-chat-tool-input">{input}</pre>
          ) : null}
          {outputText !== "" ? (
            <pre
              className={`agent-chat-mono agent-chat-tool-output${failed ? " is-error" : ""}`}
            >
              {outputText}
            </pre>
          ) : null}
          {imageCount > 0 ? (
            <div className="agent-chat-tool-images">
              {imageCount === 1 ? "1 image attachment" : `${imageCount} image attachments`}
            </div>
          ) : null}
          {input === "" && outputText === "" && imageCount === 0 ? (
            <div className="agent-chat-tool-images">No input or output recorded.</div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function SystemRow({ item }: { item: ConversationItem }) {
  const label =
    item.type === "context_compaction"
      ? "Context compacted"
      : item.type === "error"
        ? "Error"
        : item.type === "interrupted"
          ? "Stopped"
          : "Event";
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

export function StatusIndicator({ status }: { status: ConversationItem["status"] }) {
  if (status === "in_progress") {
    return (
      <output className="agent-chat-status is-in-progress" data-status={status}>
        <span className="agent-chat-spinner" aria-hidden="true" />
        <span className="agent-chat-visually-hidden">In progress</span>
      </output>
    );
  }
  return (
    <span
      className={`agent-chat-status is-${status}`}
      data-status={status}
      aria-label={status === "failed" ? "Failed" : status === "declined" ? "Declined" : "Completed"}
    >
      {statusGlyph(status)}
    </span>
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
      ? "Agent is waiting for your input"
      : request.request_type === "tool_approval"
        ? "Agent is waiting for permission"
        : "Agent is waiting";
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
