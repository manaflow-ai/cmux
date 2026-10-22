// A background task's terminal (plans/cmux-next/background-task-terminal-DESIGN.md): a click on a
// background task row asks the host to open a read-only terminal tab beside the chat that replays
// everything the task printed and follows it while it runs (`acpmux process show --follow`). The
// host finds the process from this chat's session and the tool call that started it.
import { postNative } from "./native";

/// Opens the terminal of the background task tool call `toolCallId` started. Resolves whether the
/// host opened one: false outside the app, or for a chat whose processes it cannot read (another
/// machine's).
export async function openProcessTerminal(toolCallId: string): Promise<boolean> {
  if (!toolCallId) return false;
  try {
    const reply = await postNative<{ opened?: boolean } | null>("chat.processTerminal", { toolCallId });
    return reply?.opened !== false;
  } catch {
    return false;
  }
}

/// Whether a background task's terminal can open for a chat with this summary: one on this Mac.
/// A peer's (SSH) or Cloud chat's processes run on that machine, which the host cannot read
/// (AgentPaneProcessViewer `open` refuses a remote chat).
export const opensProcessTerminal = (summary?: { peer?: string; host?: string; hostKind?: string }) =>
  !summary?.peer && !(summary?.host && summary.hostKind !== "local");

/// What a background command's row or tray line opens: its terminal in a chat on this Mac, else the
/// Bash call that started it in the transcript (`showCall`, false when no loaded row holds it).
/// Resolves which one opened, `none` when neither could.
export async function openCommand(
  toolCallId: string | undefined,
  { local, showCall }: { local: boolean; showCall?: (toolCallId: string) => boolean },
): Promise<"terminal" | "call" | "none"> {
  if (!toolCallId) return "none";
  if (local && (await openProcessTerminal(toolCallId))) return "terminal";
  return showCall?.(toolCallId) ? "call" : "none";
}
