// Mounts the Chat Colors page: one page for the app, loaded once and kept, shown in the native
// floating panel (HomeChatColorsService.swift). Each open arrives as a `session` event; the host then
// streams the chat's `state` after every change. main.tsx boots it; tests mount it directly.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { createStrings, type Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";
import { languageDirection } from "../../ui/UiProvider";
import table from "./generated/strings.json";
import { ChatColorsPanel } from "./ChatColorsPanel";
import { ChatColorsOps, type ChatColorRole, type ChatColorsSession, type ChatColorsState } from "./host";

export interface MountedChatColors {
  /** The open session (empty before the first open). */
  readonly session: () => ChatColorsSession;
  /** The state the page draws (null before the session's first one). */
  readonly state: () => ChatColorsState | null;
}

export function mountChatColors(
  root: HTMLElement,
  client: PageClient | null,
  strings: Strings = createStrings(table),
  makeRoot: typeof createRoot = createRoot,
): MountedChatColors {
  let session: ChatColorsSession = { id: "", conversation: "", name: "" };
  let state: ChatColorsState | null = null;
  const reactRoot = makeRoot(root);
  // Every call names its session; the host refuses one for a chat the panel no longer shows.
  const send = (op: string, params: Record<string, unknown> = {}) => {
    if (!session.id) return;
    void client?.call(op, { session: session.id, ...params }).catch((error: unknown) => {
      console.error(`chat colors: the host refused ${op}`, error);
    });
  };
  const render = () => {
    reactRoot.render(
      <ChatColorsPanel
        strings={strings}
        state={state}
        onPick={(role: ChatColorRole, color: string | null) => send(ChatColorsOps.set, { role, color })}
        onCustom={(role: ChatColorRole) => send(ChatColorsOps.customColor, { role })}
        onReset={() => send(ChatColorsOps.reset)}
        onDone={() => send(ChatColorsOps.done)}
      />,
    );
  };
  // Escape closes the panel; Return presses Done unless a focused control takes it (a swatch).
  document.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || event.isComposing) return;
    const onControl = event.target instanceof Element && event.target.closest("button") !== null;
    if (event.key === "Escape" || (event.key === "Enter" && !onControl)) {
      event.preventDefault();
      send(ChatColorsOps.done);
    }
  });
  document.documentElement.lang = strings.language;
  document.documentElement.dir = languageDirection(strings.language);
  document.title = strings.t("home.chatColors.title");
  flushSync(render);
  // The two streams may arrive in either order: a state for a session not open yet waits for it,
  // and a session draws the state already sent for it.
  let pending: ChatColorsState | null = null;
  const show = (next: ChatColorsState | null) => {
    state = next;
    // Synchronous, so a colour panel drag redraws in the frame it lands in.
    flushSync(render);
  };
  if (client) {
    void client
      .subscribe<ChatColorsSession>(ChatColorsOps.session, (next) => {
        session = next;
        // A new chat draws nothing of the old chat's colours under its title.
        show(pending?.session === next.id ? pending : null);
        pending = null;
      })
      .catch(() => undefined);
    void client
      .subscribe<ChatColorsState>(ChatColorsOps.state, (next) => {
        if (next.session === session.id) show(next);
        else pending = next;
      })
      .catch(() => undefined);
  }
  return { session: () => session, state: () => state };
}
