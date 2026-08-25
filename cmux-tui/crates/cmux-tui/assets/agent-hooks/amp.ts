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
        thread: context?.thread,
        cwd: process.cwd(),
      },
    });
  } catch (_) {
    return;
  }
  const child = spawn(helper, ["amp", nativeEvent], {
    env: process.env,
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.stdin.end(payload);
}

export default function cmuxTuiJournal(amp: any) {
  amp.on("session.start", async (event: unknown, context: any) => {
    emit("session.start", event, context);
  });
  amp.on("agent.start", async (event: unknown, context: any) => {
    emit("agent.start", event, context);
  });
  amp.on("tool.call", async (event: unknown, context: any) => {
    emit("tool.call", event, context);
    return { action: "allow" as const };
  });
  amp.on("tool.result", async (event: unknown, context: any) => {
    emit("tool.result", event, context);
  });
  amp.on("agent.end", async (event: unknown, context: any) => {
    emit("agent.end", event, context);
  });
}
