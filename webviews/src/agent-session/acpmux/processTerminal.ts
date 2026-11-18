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

type ChatHost = { peer?: string; host?: string; hostKind?: string };

/// Whether the chat runs on this Mac, so this page reads its processes' output (`process/tail`) and
/// its local files itself: another machine's acpmux refuses process methods to this page.
export const chatProcessesHere = (summary?: ChatHost) =>
  !summary?.peer && !(summary?.host && summary.hostKind !== "local");

/// Whether a background task's terminal can open for a chat with this summary: one on this Mac, or
/// a Cloud chat, whose terminal opens on its machine and reads that machine's acpmux there
/// (AgentPaneProcessViewer `onChatMachine`; "whatever works on a local chat should work on a Cloud
/// chat", cmuxterm-hq#7856). A peer's chat shows the call that started the task instead.
export const opensProcessTerminal = (summary?: ChatHost) =>
  chatProcessesHere(summary) || (!summary?.peer && summary?.hostKind === "cloud");

/// What a background command's row or tray line opens: its terminal where one opens, else the
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
