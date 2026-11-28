const appendEvent = journalPlugin("omp");
function emit(event: string, value: unknown, context: any) {
  return appendEvent(event, { event: value, context: { cwd: context?.cwd ?? process.cwd() } });
}
export default function cmuxTuiJournal(omp: any) {
  for (const event of ["session_start", "before_agent_start", "agent_start", "turn_start", "turn_end", "tool_call", "tool_result", "agent_end", "agent_settled", "session_shutdown"]) {
    omp.on(event, (value: unknown, context: any) => emit(event, value, context));
  }
}
