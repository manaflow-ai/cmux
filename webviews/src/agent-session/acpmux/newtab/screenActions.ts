// The new tab screen's actions as host requests (plans/cmux-next/new-tab.md section 5). An agent
// row starts the chat in this page; everything else asks the host to replace the tab.
import type { NewTabScreenActions } from "./NewTabScreen";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export function newTabScreenActions(deps: {
  callNative: Native;
  cwd?: string;
  /// The page leaves the new tab screen (it becomes a chat).
  leave(): void;
  selectSession(sessionId: string): void;
  showAllChats(): void;
}): NewTabScreenActions {
  const { callNative, cwd } = deps;
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  const remember = (agent: string) => ignore(callNative("newTab.remember", { agent }));
  return {
    onAsk(harness, text, projectCwd) {
      remember(harness);
      deps.leave();
      const folder = projectCwd ?? cwd;
      const params: Record<string, unknown> = { harness, ...(folder ? { cwd: folder } : {}) };
      ignore(callNative("chat.new", params).then(() => (text ? callNative("chat.send", { text }) : undefined)));
    },
    onOpen: (url) => {
      if (url.startsWith("file://")) return ignore(callNative("file.open", { path: decodeURIComponent(new URL(url).pathname), where: "tab" }));
      ignore(callNative("tab.open", { kind: "browser", text: url }));
    },
    onAction: (id) => ignore(callNative("app.action", { id })),
    onSearch: (text) => ignore(callNative("tab.open", { kind: "browser", text, search: true })),
    // Typed, never run: the user presses Return in the terminal (a paste never runs by itself).
    onTerminal: (command, projectCwd) =>
      ignore(callNative("tab.open", { kind: "terminal", text: command, run: false, ...((projectCwd ?? cwd) ? { cwd: projectCwd ?? cwd } : {}) })),
    onTypeAhead: (command) => ignore(callNative("tab.typeAhead", { text: command })),
    onJump: (target, id) => ignore(callNative("tab.jump", { target, id })),
    onOpenSession(sessionId) {
      deps.leave();
      deps.selectSession(sessionId);
    },
    onShowAll: deps.showAllChats,
    onTouched: () => ignore(callNative("newTab.touched")),
  };
}
