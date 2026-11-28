const appendEvent = journalPlugin("pi");

function emit(nativeEvent: string, event: unknown, context: any) {
  return appendEvent(nativeEvent, { event, context: { session_id: context?.sessionManager?.getSessionId?.(), cwd: context?.cwd } });
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
      return emit(eventName, event, context);
    });
  }
}
