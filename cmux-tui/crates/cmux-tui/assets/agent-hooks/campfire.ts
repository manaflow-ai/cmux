// cmux-tui-journal-plugin
import { spawn } from "node:child_process";
const helper = process.env.CMUX_TUI_HOOK;
function emit(event: string, value: unknown): void {
  if (!process.env.CMUX_TUI_SOCKET || !process.env.CMUX_TUI_TERMINAL_ID || !helper) return;
  const child = spawn(helper, ["campfire", event], { env: process.env, stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => {}); child.stdin.on("error", () => {});
  child.stdin.end(JSON.stringify({ event: value, context: { cwd: process.cwd() } }));
}
export default function cmuxTuiJournal(campfire: any) {
  for (const event of ["session_start", "prompt_submit", "turn_start", "turn_end", "tool_call", "tool_result", "agent_end", "session_end"]) {
    campfire.on(event, (value: unknown) => emit(event, value));
  }
}
