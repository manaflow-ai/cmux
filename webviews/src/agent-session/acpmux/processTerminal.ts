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
