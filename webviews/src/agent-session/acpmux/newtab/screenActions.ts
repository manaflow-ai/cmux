// The new tab screen's actions as host requests (plans/cmux-next/new-tab.md section 5). An agent
// row starts the chat in this page; everything else asks the host to replace the tab.
import type { AllChatsPage } from "./AllChatsList";
import type { NewTabScreenActions } from "./NewTabScreen";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export function newTabScreenActions(deps: {
  callNative: Native;
  /// The tab's inherited folder: where a terminal opened from the page starts.
  cwd?: string;
  /// The folder a chat from the page starts in: the chat's start folder (startFolder.tsx), which
  /// the host named. Never the inherited folder: a fresh workspace's page sits at `~` (cx-nn3e).
  chatCwd?: string;
  /// The page leaves the new tab screen (it becomes a chat).
  leave(): void;
  selectSession(sessionId: string): void;
  showAllChats(): void;
  /// Runs a shell mode command in the chat the page becomes, in `cwd` (shell/shellRuns.ts).
  runShell(command: string, cwd?: string): void;
  inputReady?(token: string): void;
  /// A folder the user picked on the page goes through the host first (startFolder.tsx): `start`
  /// runs only with a folder it took; the home folder is asked about once.
  requestFolder?(cwd: string, start: (folder: string) => void): void;
}): NewTabScreenActions {
  const { callNative, cwd } = deps;
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  const remember = (agent: string) => ignore(callNative("newTab.remember", { agent }));
  return {
    onAsk(harness, text, picked) {
      remember(harness);
      deps.leave();
      const start = (folder?: string) =>
        ignore(
          callNative("chat.new", { harness, ...(folder ? { cwd: folder } : {}) }).then(() =>
            text ? callNative("chat.send", { text }) : undefined,
          ),
        );
      // The page seeds its project with the inherited folder (`~` in a fresh workspace): that is no
      // pick, so the chat starts in its start folder (the host named it). A real pick goes through
      // the host first (cx-nn3e).
      if (picked && picked !== cwd) {
        if (deps.requestFolder) deps.requestFolder(picked, start);
        else start(picked);
      } else start(deps.chatCwd);
    },
    onOpen: (url) => {
      if (url.startsWith("file://"))
        return ignore(callNative("file.open", { path: decodeURIComponent(new URL(url).pathname), where: "tab" }));
      ignore(callNative("tab.open", { kind: "browser", text: url }));
    },
    onSearch: (text) => ignore(callNative("tab.open", { kind: "browser", text, search: true })),
    // `!cmd`: the page becomes a chat in its folder, its first block the command; no terminal tab.
    onShell(command) {
      deps.leave();
      ignore(callNative("tab.open", { kind: "terminal", text: command, run: true, ...(cwd ? { cwd } : {}) }));
    },
    onJump: (target, id) => ignore(callNative("tab.jump", { target, id })),
    onOpenSession(sessionId) {
      deps.leave();
      deps.selectSession(sessionId);
    },
    // A chat opens in a new workspace (the host's Open Chat path), so this page stays the New
    // Tab page instead of turning into an empty chat.
    onOpenChat: (key) => ignore(callNative("chats.open", { key })),
    onOpenChatInTerminal: (key) => ignore(callNative("chats.openInTerminal", { key })),
    loadChatsPage: (params) => callNative("chats.page", params) as Promise<AllChatsPage | undefined>,
    onShowAll: deps.showAllChats,
    onRunAction: (id) => ignore(callNative("action.run", { id })),
    onAddHarness: () => ignore(callNative("action.run", { id: "palette.addHarness" })),
    onTouched: () => ignore(callNative("newTab.touched")),
    onInputReady: (token) => ignore(callNative("newTab.inputReady", { token })),
  };
}
