// The classic New Tab page's submit (Terminal | Browser | Agent, `NewTabPage`). A terminal or
// browser tab is the host's to make, so it opens at once, also before acpmux answered the
// handshake; only a chat waits for acpmux (cx-hnpxh). A slow handshake used to hold a terminal's
// Return, and its refusal then vanished with nothing on the page.
import type { NewTabChat, TabKind } from "../NewTabPage";
import type { ComposerAttachment } from "../attachments";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export function newTabPageSubmit(deps: {
  callNative: Native;
  /// Runs `run` once acpmux answered the handshake (in order with the page's other waits).
  whenHandshaken(run: () => void): void;
  /// The page becomes a chat asking `text` (in `cwd`).
  startChat(text: string, cwd?: string, attachments?: ComposerAttachment[], chat?: NewTabChat): void;
}): (
  kind: TabKind,
  text: string,
  cwd?: string,
  attachments?: ComposerAttachment[],
  chat?: NewTabChat,
) => Promise<void> | undefined {
  return (kind, text, cwd, attachments, chat) => {
    if (kind === "agent") {
      deps.whenHandshaken(() => deps.startChat(text, cwd, attachments, chat));
      return undefined;
    }
    // The page shows a refusal under the field (NewTabPage).
    return deps.callNative("tab.open", cwd ? { kind, text, cwd } : { kind, text }).then(() => undefined);
  };
}
