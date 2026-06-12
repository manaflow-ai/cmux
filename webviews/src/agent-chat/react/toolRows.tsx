// Rich tool rows for the /agent-chat timeline: file changes render as real
// diffs, command executions get a prompt line + exit badge + output block,
// file reads show path + clamped preview, and web searches show query +
// result links. All parsing lives in toolData.ts (pure, unit-tested); these
// components only render the typed view models. Rows receive item value
// snapshots, never store references; expand/collapse is per-row local state.
//
// This module also owns the shared row primitives (rowDataProps,
// StatusIndicator) so rows.tsx imports from here and the dependency stays
// one-directional.

import { useState } from "react";
import {
  agentChatLabels,
  exitCodeLabel,
  imageAttachmentLabel,
  moreLinesNotShownLabel,
  showMoreLinesLabel,
  unchangedLinesLabel,
} from "../labels";
import type { ConversationItem } from "../protocol";
import { formatToolInput, statusGlyph, toolItemTitle, toolTypeGlyph, toolTypeLabel } from "./display";
import {
  clampTextLines,
  commandExecutionView,
  fileChangeDiffs,
  fileViewData,
  webSearchView,
  type DiffLine,
  type FileDiff,
  type FileViewData,
} from "./toolData";

/** Lines of diff shown before the expand toggle. */
const DIFF_CLAMP_LINES = 14;
/** Lines of file preview / search output shown before the expand toggle. */
const PREVIEW_CLAMP_LINES = 12;

export function rowDataProps(item: ConversationItem) {
  return {
    "data-item-id": item.id,
    "data-item-type": item.type,
    "data-item-status": item.status,
  };
}

export function StatusIndicator({ status }: { status: ConversationItem["status"] }) {
  if (status === "in_progress") {
    return (
      <output className="agent-chat-status is-in-progress" data-status={status}>
        <span className="agent-chat-spinner" aria-hidden="true" />
        <span className="agent-chat-visually-hidden">{agentChatLabels.statusInProgress}</span>
      </output>
    );
  }
  return (
    <span
      className={`agent-chat-status is-${status}`}
      data-status={status}
      aria-label={
        status === "failed"
          ? agentChatLabels.statusFailed
          : status === "declined"
            ? agentChatLabels.statusDeclined
            : agentChatLabels.statusCompleted
      }
    >
      {statusGlyph(status)}
    </span>
  );
}

/**
 * Routes a tool-shaped item to its rich renderer, falling back to generic.
 * `provider` is the session's provider id (value snapshot), used to scope
 * provider-specific output parsing.
 */
export function RichToolRow({
  item,
  provider = null,
}: {
  item: ConversationItem;
  provider?: string | null;
}) {
  if (item.type === "file_change") {
    return <FileChangeRow item={item} />;
  }
  if (item.type === "command_execution") {
    return <CommandRow item={item} provider={provider} />;
  }
  if (item.type === "web_search") {
    return <WebSearchRow item={item} />;
  }
  if (item.type === "dynamic_tool_call") {
    const data = fileViewData(item);
    if (data !== null) {
      return <FileViewRow item={item} data={data} />;
    }
  }
  return <GenericToolRow item={item} />;
}

// ---------------------------------------------------------------------------
// File changes
// ---------------------------------------------------------------------------

function FileChangeRow({ item }: { item: ConversationItem }) {
  // Parse work is bounded (toolData caps source chars and DiffLine count) and
  // the React Compiler memoizes it on the item snapshot, so re-renders of the
  // timeline do not re-diff unchanged items.
  const diffs = fileChangeDiffs(item);
  if (diffs.length === 0) {
    // Sparse hook-sourced item or an input shape we do not understand.
    return <GenericToolRow item={item} />;
  }
  const failed = item.status === "failed" || item.output?.is_error === true;
  const errorText = failed ? (item.output?.text ?? "") : "";
  return (
    <div className="agent-chat-row agent-chat-tool-row agent-chat-file-change-row" {...rowDataProps(item)}>
      {diffs.map((diff, index) => (
        <div className="agent-chat-file-change" key={diff.path ?? index}>
          <div className="agent-chat-file-change-header">
            {index === 0 ? <StatusIndicator status={item.status} /> : null}
            <span className="agent-chat-badge agent-chat-tool-badge">
              <span aria-hidden="true">{toolTypeGlyph(item.type)}</span> {toolTypeLabel(item.type)}
            </span>
            <span className="agent-chat-file-path">
              {diff.path ?? agentChatLabels.diffFallbackTitle}
            </span>
            {diff.op === "create" ? (
              <span className="agent-chat-badge agent-chat-op-badge is-create">
                {agentChatLabels.newFileBadge}
              </span>
            ) : null}
            {diff.op === "delete" ? (
              <span className="agent-chat-badge agent-chat-op-badge is-delete">
                {agentChatLabels.deletedFileBadge}
              </span>
            ) : null}
            <span className="agent-chat-diff-counts">
              <span className="agent-chat-diff-added-count">+{diff.addedCount}</span>{" "}
              <span className="agent-chat-diff-removed-count">−{diff.removedCount}</span>
            </span>
          </div>
          {diff.lines.length > 0 ? <DiffBlock diff={diff} /> : null}
        </div>
      ))}
      {errorText !== "" ? (
        <pre className="agent-chat-mono agent-chat-tool-output is-error">{errorText}</pre>
      ) : null}
    </div>
  );
}

function diffLineSign(kind: DiffLine["kind"]): string {
  if (kind === "add") {
    return "+";
  }
  if (kind === "del") {
    return "-";
  }
  return " ";
}

function diffLineText(line: DiffLine): string {
  if (line.kind !== "hunk") {
    return line.text;
  }
  if (line.collapsedCount !== undefined) {
    return unchangedLinesLabel(line.collapsedCount);
  }
  return line.text !== "" ? line.text : "⋯";
}

function DiffBlock({ diff }: { diff: FileDiff }) {
  const [expanded, setExpanded] = useState(false);
  const clamped = !expanded && diff.lines.length > DIFF_CLAMP_LINES;
  const visible = clamped ? diff.lines.slice(0, DIFF_CLAMP_LINES) : diff.lines;
  return (
    <div className="agent-chat-diff">
      {visible.map((line, index) => (
        <div className={`agent-chat-diff-line is-${line.kind}`} key={index}>
          <span className="agent-chat-diff-sign" aria-hidden="true">
            {diffLineSign(line.kind)}
          </span>
          <span className="agent-chat-diff-text">{diffLineText(line)}</span>
        </div>
      ))}
      {!clamped && (diff.sourceTruncated || diff.truncatedLineCount > 0) ? (
        <div className="agent-chat-diff-line is-hunk">
          <span className="agent-chat-diff-sign" aria-hidden="true">
            {" "}
          </span>
          <span className="agent-chat-diff-text">
            {diff.sourceTruncated
              ? agentChatLabels.diffSourceTruncated
              : moreLinesNotShownLabel(diff.truncatedLineCount)}
          </span>
        </div>
      ) : null}
      {clamped || (expanded && diff.lines.length > DIFF_CLAMP_LINES) ? (
        <button
          type="button"
          className="agent-chat-clamp-toggle"
          onClick={() => setExpanded((current) => !current)}
        >
          {clamped
            ? showMoreLinesLabel(diff.lines.length - DIFF_CLAMP_LINES)
            : agentChatLabels.showLess}
        </button>
      ) : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Command executions
// ---------------------------------------------------------------------------

function CommandRow({
  item,
  provider,
}: {
  item: ConversationItem;
  provider: string | null;
}) {
  const [expanded, setExpanded] = useState(false);
  const view = commandExecutionView(item, provider);
  const failed =
    item.status === "failed" ||
    item.output?.is_error === true ||
    (view.exitCode !== null && view.exitCode !== 0);
  return (
    <div className="agent-chat-row agent-chat-tool-row agent-chat-command-row" {...rowDataProps(item)}>
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
        <span className="agent-chat-tool-title">{view.command ?? toolItemTitle(item)}</span>
        {view.exitCode !== null ? (
          <span
            className={`agent-chat-exit-badge ${view.exitCode === 0 ? "is-success" : "is-failure"}`}
          >
            {exitCodeLabel(view.exitCode)}
          </span>
        ) : null}
        {view.durationText !== null ? (
          <span className="agent-chat-duration">{view.durationText}</span>
        ) : null}
        <span className="agent-chat-disclosure-chevron" aria-hidden="true">
          {expanded ? "▾" : "▸"}
        </span>
      </button>
      {expanded ? (
        <div className="agent-chat-tool-detail">
          {view.command !== null ? (
            <div className="agent-chat-command-line">
              <span className="agent-chat-command-prompt" aria-hidden="true">
                ❯
              </span>
              <span className="agent-chat-command-text">{view.command}</span>
            </div>
          ) : null}
          {view.output !== null ? (
            <pre className={`agent-chat-mono agent-chat-tool-output${failed ? " is-error" : ""}`}>
              {view.output}
            </pre>
          ) : (
            <div className="agent-chat-tool-images">{agentChatLabels.noCommandOutput}</div>
          )}
        </div>
      ) : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
// File views (Read-like dynamic tools)
// ---------------------------------------------------------------------------

function FileViewRow({ item, data }: { item: ConversationItem; data: FileViewData }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="agent-chat-row agent-chat-tool-row agent-chat-file-view-row" {...rowDataProps(item)}>
      <button
        type="button"
        className="agent-chat-disclosure agent-chat-tool-summary"
        aria-expanded={expanded}
        onClick={() => setExpanded((current) => !current)}
      >
        <StatusIndicator status={item.status} />
        <span className="agent-chat-badge agent-chat-tool-badge">
          <span aria-hidden="true">{toolTypeGlyph(item.type)}</span>{" "}
          {item.tool_name ?? toolTypeLabel(item.type)}
        </span>
        <span className="agent-chat-tool-title">{data.path}</span>
        <span className="agent-chat-disclosure-chevron" aria-hidden="true">
          {expanded ? "▾" : "▸"}
        </span>
      </button>
      {expanded ? (
        <div className="agent-chat-tool-detail">
          {data.preview !== null ? (
            <ClampedMonoText text={data.preview} />
          ) : (
            <div className="agent-chat-tool-images">{agentChatLabels.noFilePreview}</div>
          )}
        </div>
      ) : null}
    </div>
  );
}

function ClampedMonoText({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  const clamp = clampTextLines(text, PREVIEW_CLAMP_LINES);
  return (
    <div className="agent-chat-clamped-block">
      <pre className="agent-chat-mono agent-chat-tool-output">
        {expanded ? text : clamp.text}
      </pre>
      {clamp.truncated ? (
        <button
          type="button"
          className="agent-chat-clamp-toggle"
          onClick={() => setExpanded((current) => !current)}
        >
          {expanded ? agentChatLabels.showLess : showMoreLinesLabel(clamp.hiddenLines)}
        </button>
      ) : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Web searches
// ---------------------------------------------------------------------------

function WebSearchRow({ item }: { item: ConversationItem }) {
  const [expanded, setExpanded] = useState(false);
  const view = webSearchView(item);
  return (
    <div className="agent-chat-row agent-chat-tool-row agent-chat-web-search-row" {...rowDataProps(item)}>
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
        <span className="agent-chat-tool-title">
          {view.query ?? agentChatLabels.searchQueryFallback}
        </span>
        <span className="agent-chat-disclosure-chevron" aria-hidden="true">
          {expanded ? "▾" : "▸"}
        </span>
      </button>
      {expanded ? (
        <div className="agent-chat-tool-detail">
          {view.results.length > 0 ? (
            <ul className="agent-chat-search-results">
              {view.results.map((result) => (
                <li className="agent-chat-search-result" key={result.url}>
                  {/* Same anchor policy as the sanitized markdown renderer:
                      http/https only (enforced in toolData), rel=noreferrer,
                      navigation handled by the host like markdown links. */}
                  <a href={result.url} rel="noreferrer">
                    {result.title}
                  </a>
                  <span className="agent-chat-search-url">{result.url}</span>
                </li>
              ))}
            </ul>
          ) : view.text !== null ? (
            <ClampedMonoText text={view.text} />
          ) : (
            <div className="agent-chat-tool-images">{agentChatLabels.noToolPayload}</div>
          )}
        </div>
      ) : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Generic fallback (mcp_tool_call, unrecognized dynamic tools, sparse items)
// ---------------------------------------------------------------------------

function GenericToolRow({ item }: { item: ConversationItem }) {
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
            <div className="agent-chat-tool-images">{imageAttachmentLabel(imageCount)}</div>
          ) : null}
          {input === "" && outputText === "" && imageCount === 0 ? (
            <div className="agent-chat-tool-images">{agentChatLabels.noToolPayload}</div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
