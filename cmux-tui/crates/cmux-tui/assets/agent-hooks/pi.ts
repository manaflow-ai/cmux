// cmux-tui-journal-plugin
import { spawn } from "node:child_process";

const helper = process.env.CMUX_TUI_HOOK;

function emit(nativeEvent: string, event: unknown, context: any): void {
  if (!process.env.CMUX_TUI_SOCKET || !process.env.CMUX_TUI_TERMINAL_ID || !helper) return;
  let payload: string;
  try {
    payload = JSON.stringify({
      event,
      context: {
        session_id: context?.sessionManager?.getSessionId?.(),
        cwd: context?.cwd,
      },
    });
  } catch (_) {
    return;
  }
  const child = spawn(helper, ["pi", nativeEvent], {
    env: process.env,
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.stdin.end(payload);
}

export default function cmuxTuiJournal(pi: any) {
  for (const eventName of [
    "session_start",
    "session_info_changed",
    "session_before_switch",
    "session_before_fork",
    "session_before_tree",
    "session_tree",
    "before_agent_start",
    "agent_start",
    "turn_start",
    "turn_end",
    "message_start",
    "message_end",
    "tool_execution_start",
    "tool_execution_end",
    "tool_call",
    "tool_result",
    "session_before_compact",
    "session_compact",
    "agent_end",
    "agent_settled",
    "model_select",
    "thinking_level_select",
    "user_bash",
    "session_shutdown",
  ]) {
    pi.on(eventName, (event: unknown, context: any) => {
      emit(eventName, event, context);
    });
  }
}
