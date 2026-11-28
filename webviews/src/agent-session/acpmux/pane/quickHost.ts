import { QUICK_MESSAGES } from "../paneSurface";
import { callNative } from "../callNative";

/// Asks the host to show the Quick Composer's chat in a window.
export const postOpenInWindow = (sessionId: string) =>
  void callNative(QUICK_MESSAGES.openInWindow, { sessionId }).catch(() => undefined);

/// The longest workspace name a background start asks for (AgentPaneQuickStart.maximumName).
const QUICK_NAME_LIMIT = 80;

/// A started chat's workspace name: the prompt's first non-empty line, or none.
export function quickChatName(text: string): string | undefined {
  const line = text
    .split("\n")
    .map((part) => part.trim())
    .find((part) => part !== "");
  // By code point, so the cut never splits a surrogate pair.
  return line ? Array.from(line).slice(0, QUICK_NAME_LIMIT).join("") : undefined;
}

/// Asks the host to put the Quick Composer's started chat in the sidebar, in the background.
export const postStartInBackground = (sessionId: string, cwd: string | undefined, name: string | undefined) =>
  void callNative(QUICK_MESSAGES.startInBackground, {
    sessionId,
    ...(cwd ? { cwd } : {}),
    ...(name ? { name } : {}),
  }).catch(() => undefined);
