const appendEvent = journalPlugin("campfire");
function emit(event: string, value: unknown) {
  return appendEvent(event, { event: value, context: { cwd: process.cwd() } });
}
export default function cmuxTuiJournal(campfire: any) {
  for (const event of ["session_start", "prompt_submit", "turn_start", "turn_end", "tool_call", "tool_result", "agent_end", "session_end"]) {
    campfire.on(event, (value: unknown) => emit(event, value));
  }
}
