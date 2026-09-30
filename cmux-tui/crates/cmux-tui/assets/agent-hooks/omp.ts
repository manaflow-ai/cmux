// cmux-tui-journal-plugin
import { spawn } from "node:child_process";
const helper = process.env.CMUX_TUI_HOOK;
function emit(event: string, value: unknown, context: any): void {
  if (!process.env.CMUX_TUI_SOCKET || !process.env.CMUX_TUI_TERMINAL_ID || !helper) return;
  const child = spawn(helper, ["omp", event], { env: process.env, stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => {}); child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify({ event: value, context: { cwd: context?.cwd ?? process.cwd() } }));
}
export default function cmuxTuiJournal(omp: any) {
  for (const event of ["session_start", "before_agent_start", "agent_start", "turn_start", "turn_end", "tool_call", "tool_result", "agent_end", "agent_settled", "session_shutdown"]) {
    omp.on(event, (value: unknown, context: any) => emit(event, value, context));
  }
}
