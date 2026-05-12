/**
 * MessageList component — renders the conversation history plus an in-progress
 * streaming state at the bottom.
 */
import React from "react";
import { Box, Text, useStdout } from "ink";
// ink-spinner types: the default export is the Spinner component
import Spinner from "ink-spinner";
import { theme, prefix } from "./theme.js";
import type {
  Message,
  ContentBlock,
  ToolUseBlock,
  ToolResultBlock,
  ThinkingBlock,
  TextBlock,
} from "../core/types.js";

// ---------------------------------------------------------------------------
// StreamingState
// ---------------------------------------------------------------------------

export interface StreamingState {
  text: string;
  thinking: string;
  toolCalls: Array<{ id: string; name: string; inputJsonStr: string }>;
  status: "streaming" | "tool_running" | "waiting_for_tool" | "done" | "error";
  toolStatus?: { name: string; output: string };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function truncateLines(text: string, maxLines: number): { lines: string[]; truncated: boolean } {
  const all = text.split("\n");
  if (all.length <= maxLines) return { lines: all, truncated: false };
  return { lines: all.slice(0, maxLines), truncated: true };
}

function prettyJson(value: unknown, columns: number): string {
  try {
    const raw = typeof value === "string" ? value : JSON.stringify(value, null, 2);
    // Wrap lines to column width
    return raw;
  } catch {
    return String(value);
  }
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function ToolUse({ block, columns }: { block: ToolUseBlock; columns: number }) {
  const inputStr = prettyJson(block.input, columns);
  const { lines, truncated } = truncateLines(inputStr, 5);
  return (
    <Box flexDirection="column" marginLeft={2}>
      <Text color={theme.toolName}>╭─ tool: {block.name}</Text>
      {lines.map((line, i) => (
        <Text key={i} color={theme.dim}>
          │ {line}
        </Text>
      ))}
      {truncated && (
        <Text color={theme.dim}>│ …</Text>
      )}
      <Text color={theme.toolName}>╰─</Text>
    </Box>
  );
}

function ToolResult({ block, columns }: { block: ToolResultBlock; columns: number }) {
  const rawContent =
    typeof block.content === "string"
      ? block.content
      : block.content.map((b) => (b.type === "text" ? b.text : "[image]")).join("\n");

  const { lines, truncated } = truncateLines(rawContent, 20);
  const color = block.is_error ? theme.toolError : theme.dim;
  return (
    <Box flexDirection="column" marginLeft={2}>
      <Text color={color}>╭─ result{block.is_error ? " (error)" : ""}</Text>
      {lines.map((line, i) => (
        <Text key={i} color={color} dimColor>
          │ {line}
        </Text>
      ))}
      {truncated && (
        <Text color={color} dimColor>
          │ (truncated)
        </Text>
      )}
      <Text color={color}>╰─</Text>
    </Box>
  );
}

function ThinkingBlockView({
  block,
  showThinking,
}: {
  block: ThinkingBlock;
  showThinking: boolean;
}) {
  if (!showThinking) {
    return (
      <Text color={theme.thinking} dimColor italic>
        (thinking...)
      </Text>
    );
  }
  return (
    <Box flexDirection="column" marginLeft={2}>
      <Text color={theme.thinking} dimColor italic>
        {block.thinking}
      </Text>
    </Box>
  );
}

function ContentBlockView({
  block,
  showThinking,
  columns,
}: {
  block: ContentBlock;
  showThinking: boolean;
  columns: number;
}) {
  switch (block.type) {
    case "text":
      return <Text color={theme.assistant}>{block.text}</Text>;
    case "tool_use":
      return <ToolUse block={block} columns={columns} />;
    case "tool_result":
      return <ToolResult block={block} columns={columns} />;
    case "thinking":
      return <ThinkingBlockView block={block} showThinking={showThinking} />;
    case "image":
      return <Text color={theme.dim}>[image]</Text>;
    default:
      return null;
  }
}

function MessageView({
  message,
  showThinking,
  columns,
}: {
  message: Message;
  showThinking: boolean;
  columns: number;
}) {
  const role = message.role as "user" | "assistant" | "tool" | "system";
  const badge = prefix(role);
  const color =
    role === "user"
      ? theme.user
      : role === "assistant"
      ? theme.assistant
      : role === "tool"
      ? theme.dim
      : theme.system;

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text color={color} bold>
        {badge}
      </Text>
      {message.content.map((block, i) => (
        <ContentBlockView
          key={i}
          block={block}
          showThinking={showThinking}
          columns={columns}
        />
      ))}
    </Box>
  );
}

// ---------------------------------------------------------------------------
// StreamingMessage — rendered at the bottom while assistant is responding
// ---------------------------------------------------------------------------

function StreamingMessage({
  streaming,
  showThinking,
  columns,
}: {
  streaming: StreamingState;
  showThinking: boolean;
  columns: number;
}) {
  const { text, thinking, toolCalls, status, toolStatus } = streaming;

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Box>
        <Text color={theme.accent} bold>
          ● assistant{" "}
        </Text>
        <Text color={theme.dim}>
          <Spinner type="dots" />
        </Text>
      </Box>

      {/* Thinking */}
      {thinking.length > 0 &&
        (showThinking ? (
          <Text color={theme.thinking} dimColor italic>
            {thinking}
          </Text>
        ) : (
          <Text color={theme.thinking} dimColor italic>
            (thinking...)
          </Text>
        ))}

      {/* Streamed text */}
      {text.length > 0 && <Text color={theme.assistant}>{text}</Text>}

      {/* Accumulated tool calls */}
      {toolCalls.map((tc) => {
        const inputParsed = (() => {
          try {
            return JSON.parse(tc.inputJsonStr || "{}");
          } catch {
            return tc.inputJsonStr;
          }
        })();
        const inputStr = prettyJson(inputParsed, columns);
        const { lines, truncated } = truncateLines(inputStr, 5);
        return (
          <Box key={tc.id} flexDirection="column" marginLeft={2}>
            <Text color={theme.toolName}>╭─ tool: {tc.name}</Text>
            {lines.map((line, i) => (
              <Text key={i} color={theme.dim}>
                │ {line}
              </Text>
            ))}
            {truncated && <Text color={theme.dim}>│ …</Text>}
            <Text color={theme.toolName}>╰─</Text>
          </Box>
        );
      })}

      {/* Active tool running */}
      {status === "tool_running" && toolStatus && (
        <Box flexDirection="column" marginLeft={2}>
          <Box>
            <Text color={theme.toolName}>⟳ running: {toolStatus.name} </Text>
            <Text color={theme.dim}>
              <Spinner type="dots" />
            </Text>
          </Box>
          {toolStatus.output.length > 0 && (
            <Text color={theme.dim} dimColor>
              {toolStatus.output.slice(-500)}
            </Text>
          )}
        </Box>
      )}

      {status === "error" && (
        <Text color={theme.toolError}>● error during streaming</Text>
      )}
    </Box>
  );
}

// ---------------------------------------------------------------------------
// MessageList (main export)
// ---------------------------------------------------------------------------

export interface MessageListProps {
  messages: Message[];
  streaming?: StreamingState | null;
  showThinking?: boolean;
}

function MessageListInner({ messages, streaming, showThinking = false }: MessageListProps) {
  const { stdout } = useStdout();
  const columns = stdout?.columns ?? 80;

  return (
    <Box flexDirection="column">
      {messages.map((msg, i) => (
        <MessageView
          key={i}
          message={msg}
          showThinking={showThinking}
          columns={columns}
        />
      ))}
      {streaming != null && streaming.status !== "done" && (
        <StreamingMessage
          streaming={streaming}
          showThinking={showThinking}
          columns={columns}
        />
      )}
    </Box>
  );
}

export const MessageList = React.memo(MessageListInner, (prev, next) => {
  return (
    prev.messages.length === next.messages.length &&
    prev.streaming === next.streaming &&
    prev.showThinking === next.showThinking
  );
});
