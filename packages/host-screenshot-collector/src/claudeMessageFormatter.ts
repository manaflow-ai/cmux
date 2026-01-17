import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";

/**
 * Format Claude Agent SDK messages for human-readable logging
 */
export function formatClaudeMessage(message: SDKMessage): string {
  switch (message.type) {
    case "assistant": {
      const content = message.message.content;
      const parts: string[] = [];

      for (const block of content) {
        if (block.type === "text") {
          parts.push(`💬 ${block.text}`);
        } else if (block.type === "tool_use") {
          parts.push(formatToolUse(block.name, block.input));
        }
      }

      // Add usage info if available
      if (message.message.usage) {
        parts.push(
          `   └─ tokens: in=${message.message.usage.input_tokens} out=${message.message.usage.output_tokens}`
        );
      }

      return parts.join("\n");
    }

    case "user": {
      const content = message.message.content;
      if (typeof content === "string") {
        return `👤 User: ${content}`;
      }

      if (Array.isArray(content)) {
        const parts: string[] = [];
        for (const block of content) {
          if ("type" in block && block.type === "tool_result") {
            parts.push(formatToolResult(block.tool_use_id, block.content));
          } else if ("type" in block && block.type === "text") {
            parts.push(`👤 User: ${block.text}`);
          }
        }
        return parts.join("\n");
      }

      return `👤 User message (complex content)`;
    }

    case "result": {
      const baseInfo = `${message.num_turns} turns, ${message.duration_ms}ms`;
      if (message.subtype === "success") {
        return `
✅ Success (${baseInfo}, $${message.total_cost_usd.toFixed(4)})
   Result: ${message.result}`;
      }
      return `❌ Error: ${message.subtype} (${baseInfo}, $${message.total_cost_usd.toFixed(4)})`;
    }

    case "system": {
      switch (message.subtype) {
        case "init":
          return `
🔧 System initialized
   Model: ${message.model}
   Tools: ${message.tools.length} available
   MCP Servers: ${message.mcp_servers.map((s) => `${s.name}(${s.status})`).join(", ")}
   Permission Mode: ${message.permissionMode}`;
        case "compact_boundary":
          return `📦 Compacted (${message.compact_metadata.trigger}, ${message.compact_metadata.pre_tokens} tokens)`;
        case "hook_response":
          return `🪝 Hook: ${message.hook_name} (${message.hook_event}) - exit ${message.exit_code ?? "N/A"}`;
        case "status": {
          const status = message.status ?? "idle";
          return `🔄 Status: ${status}`;
        }
        default: {
          // Type assertion for exhaustiveness check
          const _exhaustive: never = message;
          return `🔧 System: unknown`;
        }
      }
    }

    case "tool_progress": {
      const parent =
        message.parent_tool_use_id === null
          ? ""
          : ` (child of ${message.parent_tool_use_id})`;
      return `⏳ Tool progress: ${message.tool_name} ${parent} after ${message.elapsed_time_seconds.toFixed(1)}s`;
    }

    case "auth_status": {
      const output =
        message.output.length > 0 ? ` output="${message.output.join(" | ")}"` : "";
      const error = message.error ? ` error="${message.error}"` : "";
      return `🔐 Auth status: ${message.isAuthenticating ? "authenticating" : "idle"}${output}${error}`;
    }

    case "stream_event": {
      // Skip streaming events for cleaner logs (they're partial)
      return "";
    }

    default: {
      return `❓ Unknown message type`;
    }
  }
}

function formatToolUse(
  toolName: string,
  input: Record<string, unknown>
): string {
  const emoji = getToolEmoji(toolName);
  const formattedInput = formatToolInput(toolName, input);

  return `${emoji} ${toolName}${formattedInput}`;
}

function formatToolResult(_toolUseId: string, content: unknown): string {
  let contentStr: string;

  if (typeof content === "string") {
    contentStr = content;
  } else if (Array.isArray(content)) {
    contentStr = content
      .map((item) => {
        if (
          typeof item === "object" &&
          item !== null &&
          "type" in item &&
          item.type === "tool_result"
        ) {
          return formatToolResultContent(
            (item as { content?: unknown }).content
          );
        }
        return JSON.stringify(item);
      })
      .join(" ");
  } else {
    contentStr = JSON.stringify(content);
  }

  // Truncate long results
  if (contentStr.length > 200) {
    contentStr = contentStr.slice(0, 200) + "...";
  }

  const isError =
    typeof content === "object" &&
    content !== null &&
    "is_error" in content &&
    content.is_error === true;

  return `   ${isError ? "❌" : "✓"} Result: ${contentStr}`;
}

function formatToolResultContent(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  return JSON.stringify(content);
}

function formatToolInput(
  toolName: string,
  input: Record<string, unknown>
): string {
  // Special formatting for common tools
  switch (toolName) {
    case "Read": {
      const filePath = input.file_path;
      return ` ${filePath}`;
    }

    case "Write": {
      const filePath = input.file_path;
      const lines = String(input.content || "").split("\n").length;
      return ` ${filePath} (${lines} lines)`;
    }

    case "Edit": {
      const filePath = input.file_path;
      return ` ${filePath}`;
    }

    case "Bash": {
      const command = String(input.command || "");
      const truncated = command.length > 50 ? command.slice(0, 50) + "..." : command;
      return ` ${truncated}`;
    }

    case "Glob":
    case "Grep": {
      const pattern = input.pattern;
      return ` "${pattern}"`;
    }

    case "mcp___playwright_mcp__browser_navigate": {
      const url = input.url;
      return ` → ${url}`;
    }

    case "mcp___playwright_mcp__browser_take_screenshot": {
      const name = input.name || "screenshot";
      return ` 📸 ${name}`;
    }

    case "mcp___playwright_mcp__browser_click": {
      const selector = input.selector;
      return ` ${selector}`;
    }

    case "mcp___video__start_video": {
      const name = input.name || "recording";
      return ` 🎬 Starting "${name}"`;
    }

    case "mcp___video__end_video": {
      const name = input.name || "recording";
      return ` 🛑 Ending "${name}"`;
    }

    case "TodoWrite": {
      const todos = input.todos as Array<{ content: string; status: string }>;
      if (!todos || todos.length === 0) {
        return " (0 items)";
      }

      const statusEmoji = (status: string) => {
        switch (status) {
          case "completed":
            return "✅";
          case "in_progress":
            return "⏳";
          case "pending":
            return "⭕";
          default:
            return "❓";
        }
      };

      const todoLines = todos.map(
        (todo) => `\n   ${statusEmoji(todo.status)} ${todo.content}`
      );
      return todoLines.join("");
    }

    default: {
      // For other tools, show a compact version of the input
      const keys = Object.keys(input);
      if (keys.length === 0) {
        return "";
      }
      if (keys.length === 1 && keys[0]) {
        const value = input[keys[0]];
        if (typeof value === "string" && value.length < 40) {
          return ` ${value}`;
        }
      }
      return ` {${keys.join(", ")}}`;
    }
  }
}

function getToolEmoji(toolName: string): string {
  // MCP tools - Playwright
  if (toolName.startsWith("mcp___playwright_mcp__browser_")) {
    const action = toolName.replace("mcp___playwright_mcp__browser_", "");
    switch (action) {
      case "navigate":
      case "navigate_back":
        return "🌐";
      case "click":
      case "hover":
        return "👆";
      case "take_screenshot":
      case "snapshot":
        return "📸";
      case "type":
      case "fill_form":
        return "⌨️";
      case "close":
        return "❌";
      default:
        return "🎭";
    }
  }

  // MCP tools - Video recording
  if (toolName.startsWith("mcp___video__")) {
    const action = toolName.replace("mcp___video__", "");
    switch (action) {
      case "start_video":
        return "🎬";
      case "end_video":
        return "🛑";
      default:
        return "📹";
    }
  }

  // Built-in tools
  switch (toolName) {
    case "Read":
      return "📖";
    case "Write":
      return "✍️";
    case "Edit":
      return "✏️";
    case "Bash":
      return "🔨";
    case "Glob":
      return "🔍";
    case "Grep":
      return "🔎";
    case "TodoWrite":
      return "📝";
    case "Task":
      return "🤖";
    case "WebFetch":
      return "🌐";
    case "WebSearch":
      return "🔍";
    default:
      return "🔧";
  }
}
