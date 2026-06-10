// Mock agent-chat bridge for vite dev and headless tests.
//
// Used whenever `window.webkit.messageHandlers.agentChat` is absent. Replays a
// realistic fixture conversation: `chat.subscribe` delivers a snapshot with a
// mixed item list, then a short scripted sequence of hook-sourced turn.* and
// request.* events plus item.started / item.updated / item.completed ticks on
// a timer, all through the real inbound path
// (`window.cmuxAgentChatBridge.receive`).

import type { AgentChatBridgeClient } from "./bridge";
import type {
  AgentChatBridgeInbound,
  AgentChatInitResult,
  AgentEvent,
  AgentSessionRef,
  ConversationItem,
} from "./protocol";

const MOCK_TICK_INTERVAL_MS = 1200;

const mockSession: AgentSessionRef = {
  provider: "claude",
  session_id: "6f1f5e7e-mock-4d27-9c40-agentchatdev1",
  transcript_path:
    "~/.claude/projects/-Users-dev-fun-cmux/6f1f5e7e-mock-4d27-9c40-agentchatdev1.jsonl",
  cwd: "~/fun/cmux",
  title: "Wire the /agent-chat surface",
  updated_at: "2026-06-09T17:03:21Z",
};

export function mockSnapshotItems(): ConversationItem[] {
  return [
    {
      id: "msg-1",
      type: "user_message",
      status: "completed",
      text: "Add a structured chat view for agent sessions. Start by listing the failing webview tests.",
      created_at: "2026-06-09T16:58:01Z",
    },
    {
      id: "reasoning-1",
      type: "reasoning",
      status: "completed",
      text: "The webviews app keeps tests under `test/`. I should run `bun test` first to get a baseline, then look at the failures one by one.",
      created_at: "2026-06-09T16:58:04Z",
    },
    {
      id: "tool-1",
      type: "command_execution",
      status: "completed",
      title: "bun test",
      tool_name: "Bash",
      tool_use_id: "toolu_mock_01",
      input: { command: "bun test", description: "Run webview tests" },
      output: {
        text: "12 pass\n 0 fail\nRan 12 tests across 11 files. [412ms]",
      },
      created_at: "2026-06-09T16:58:06Z",
    },
    {
      id: "msg-2",
      type: "assistant_message",
      status: "completed",
      text: "All **12 tests pass**, so there is no baseline failure. Next I will:\n\n1. Add the `/agent-chat` route\n2. Build the bridge client\n3. Render the timeline\n\n```bash\nbun run typecheck && bun test\n```",
      created_at: "2026-06-09T16:58:09Z",
    },
    {
      id: "msg-3",
      type: "user_message",
      status: "completed",
      text: "Sounds good. Check how the diff surface registers its route before you add a new one.",
      created_at: "2026-06-09T16:59:30Z",
    },
    {
      id: "plan-1",
      type: "plan",
      status: "completed",
      text: "1. Read `src/router.tsx` route registrations\n2. Mirror the `/diff` pattern for `/agent-chat`\n3. Split the surface into its own chunk",
      created_at: "2026-06-09T16:59:33Z",
    },
    {
      id: "tool-2",
      type: "dynamic_tool_call",
      status: "completed",
      title: "src/router.tsx",
      tool_name: "Read",
      tool_use_id: "toolu_mock_02",
      input: { file_path: "webviews/src/router.tsx" },
      output: { text: "createRoute({ path: \"/diff\", component: WebviewComponent })\n…" },
      created_at: "2026-06-09T16:59:35Z",
    },
    {
      id: "tool-3",
      type: "file_change",
      status: "completed",
      title: "webviews/src/router.tsx",
      tool_name: "Edit",
      tool_use_id: "toolu_mock_03",
      input: {
        file_path: "webviews/src/router.tsx",
        old_string: "path: \"/agent-session\"",
        new_string: "path: \"/agent-chat\"",
      },
      output: { text: "Edited webviews/src/router.tsx" },
      created_at: "2026-06-09T16:59:42Z",
    },
    {
      id: "tool-4",
      type: "web_search",
      status: "completed",
      title: "tanstack router hash history nested routes",
      tool_name: "WebSearch",
      tool_use_id: "toolu_mock_04",
      input: { query: "tanstack router hash history nested routes" },
      output: { text: "TanStack Router docs: createHashHistory() keeps route state in the URL fragment…" },
      created_at: "2026-06-09T17:00:01Z",
    },
    {
      id: "tool-5",
      type: "mcp_tool_call",
      status: "failed",
      title: "browser_screenshot",
      tool_name: "mcp__browser__screenshot",
      tool_use_id: "toolu_mock_05",
      input: { url: "http://localhost:5173/#/agent-chat" },
      output: { text: "Error: no browser session connected", is_error: true },
      created_at: "2026-06-09T17:00:18Z",
    },
    {
      id: "compaction-1",
      type: "context_compaction",
      status: "completed",
      text: "Context compacted (142k → 38k tokens)",
      created_at: "2026-06-09T17:00:40Z",
    },
    {
      id: "error-1",
      type: "error",
      status: "completed",
      text: "Provider stream interrupted; retrying transcript tail.",
      created_at: "2026-06-09T17:00:41Z",
    },
    {
      id: "unknown-1",
      type: "unknown",
      status: "completed",
      text: "queue-operation",
      created_at: "2026-06-09T17:00:42Z",
    },
    {
      id: "msg-4",
      type: "user_message",
      status: "completed",
      text: "Now run the verify gates and show me the summary.",
      created_at: "2026-06-09T17:02:10Z",
    },
    {
      id: "tool-6",
      type: "command_execution",
      status: "in_progress",
      title: "bun run typecheck && bun run lint:ci",
      tool_name: "Bash",
      tool_use_id: "toolu_mock_06",
      input: { command: "bun run typecheck && bun run lint:ci" },
      created_at: "2026-06-09T17:02:12Z",
    },
  ];
}

export function mockLiveEvents(startSeq: number): AgentEvent[] {
  return [
    // Hook-sourced live phase: a real turn bracket plus a request that opens
    // (banner shows) and resolves one tick later.
    {
      type: "turn.started",
      seq: startSeq,
      turn_id: "turn-mock-1",
      prompt: "Now run the verify gates and show me the summary.",
    },
    {
      type: "request.opened",
      seq: startSeq + 1,
      request_id: "req-mock-1",
      request_type: "tool_approval",
      detail: "Bash: bun run typecheck && bun run lint:ci",
    },
    {
      type: "request.resolved",
      seq: startSeq + 2,
      request_id: "req-mock-1",
      decision: "approved",
    },
    {
      type: "item.updated",
      seq: startSeq + 3,
      item: {
        id: "tool-6",
        type: "command_execution",
        status: "in_progress",
        title: "bun run typecheck && bun run lint:ci",
        tool_name: "Bash",
        tool_use_id: "toolu_mock_06",
        input: { command: "bun run typecheck && bun run lint:ci" },
        output: { text: "$ tsc --noEmit" },
        created_at: "2026-06-09T17:02:12Z",
      },
    },
    {
      type: "item.completed",
      seq: startSeq + 4,
      item: {
        id: "tool-6",
        type: "command_execution",
        status: "completed",
        title: "bun run typecheck && bun run lint:ci",
        tool_name: "Bash",
        tool_use_id: "toolu_mock_06",
        input: { command: "bun run typecheck && bun run lint:ci" },
        output: {
          text: "$ tsc --noEmit\n$ oxlint . --react-plugin --jsx-a11y-plugin --import-plugin --deny-warnings\nFound 0 warnings and 0 errors.\nFinished in 64ms on 41 files with 102 rules using 10 threads.",
        },
        created_at: "2026-06-09T17:02:12Z",
      },
    },
    {
      type: "item.started",
      seq: startSeq + 5,
      item: {
        id: "reasoning-2",
        type: "reasoning",
        status: "in_progress",
        text: "Both gates are green. Summarize the run and hand back to the user.",
        created_at: "2026-06-09T17:03:02Z",
      },
    },
    {
      type: "item.completed",
      seq: startSeq + 6,
      item: {
        id: "reasoning-2",
        type: "reasoning",
        status: "completed",
        text: "Both gates are green. Summarize the run and hand back to the user.",
        created_at: "2026-06-09T17:03:02Z",
      },
    },
    {
      type: "item.completed",
      seq: startSeq + 7,
      item: {
        id: "msg-5",
        type: "assistant_message",
        status: "completed",
        text: "Verify gates are green:\n\n- `bun run typecheck` — no errors\n- `bun run lint:ci` — 0 warnings\n\nThe `/agent-chat` surface is registered and renders this mock stream in dev.",
        created_at: "2026-06-09T17:03:20Z",
      },
    },
    {
      type: "turn.completed",
      seq: startSeq + 8,
      turn_id: "turn-mock-1",
    },
  ];
}

function deliver(message: AgentChatBridgeInbound): void {
  if (typeof window === "undefined") {
    return;
  }
  window.cmuxAgentChatBridge?.receive(message);
}

export function createMockAgentChatBridge(): AgentChatBridgeClient {
  let timer: ReturnType<typeof setInterval> | null = null;
  let disposed = false;

  const stopTimer = () => {
    if (timer !== null) {
      clearInterval(timer);
      timer = null;
    }
  };

  return {
    kind: "mock",
    init(): Promise<AgentChatInitResult> {
      return Promise.resolve({
        session: mockSession,
        daemon_status: "ready",
      });
    },
    subscribe(): Promise<void> {
      if (disposed || timer !== null) {
        return Promise.resolve();
      }
      deliver({
        type: "agent.event",
        event: { type: "snapshot", seq: 1, session: mockSession, items: mockSnapshotItems() },
      });
      const pending = mockLiveEvents(2);
      timer = setInterval(() => {
        const event = pending.shift();
        if (!event) {
          stopTimer();
          return;
        }
        deliver({ type: "agent.event", event });
      }, MOCK_TICK_INTERVAL_MS);
      return Promise.resolve();
    },
    dispose(): void {
      disposed = true;
      stopTimer();
    },
  };
}
