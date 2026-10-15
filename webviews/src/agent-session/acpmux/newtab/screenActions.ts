// The new tab screen's actions as host requests (plans/cmux-next/new-tab.md section 5). An agent
// row starts the chat in this page; everything else asks the host to replace the tab.
import type { AllChatsPage } from "./AllChatsList";
import type { NewTabScreenActions } from "./NewTabScreen";
import { environmentFolder, environmentHost, type Environment } from "../environments";
import { newWorktree } from "../startFolder";

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
  /// A saved environment's worktree (cx-ncc.104) that the host did not make: its reason, and the
  /// prompt to give back to the composer.
  worktreeFailed?(reason: string, text: string): void;
}): NewTabScreenActions {
  const { callNative, cwd } = deps;
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  const remember = (agent: string) => ignore(callNative("newTab.remember", { agent }));
  // A saved environment (cx-ncc.104) starts the chat in its first folder, on its machine: a
  // Cloud one opens the host's New Cloud Machine (its network settings apply later), an SSH one
  // starts on its peer, and a local folder marked Use worktree starts in a new worktree of it, as
  // the folder menu's New Worktree does. The harness and model are the composer's, as for any ask.
  function startInEnvironment(harness: string, text: string, model: string | undefined, environment: Environment) {
    if (environment.kind === "cloud") {
      ignore(callNative("action.run", { id: "newCloudMachine" }));
      return;
    }
    deps.leave();
    const peer = environment.kind === "ssh" ? environment.host : undefined;
    const start = (folder?: string) => {
      ignore(
        callNative("chat.new", {
          harness,
          ...(folder ? { cwd: folder } : {}),
          ...(peer ? { peer } : {}),
          ...(model ? { model } : {}),
        }),
      );
      if (text) ignore(callNative("chat.send", { text }));
    };
    const folder = environmentFolder(environment);
    if (!folder) return start(peer ? undefined : deps.chatCwd);
    // Another machine's folder is its own: this Mac's folder checks do not apply to it.
    if (peer) return start(folder);
    if (!environment.folders[0]?.worktree) {
      if (deps.requestFolder) deps.requestFolder(folder, start);
      else start(folder);
      return;
    }
    void newWorktree(callNative, folder, start)
      .then(({ ask }) => {
        // The host asks about the worktree's folder first: the same question a picked folder gets.
        if (ask) deps.requestFolder?.(ask.cwd, start);
      })
      .catch((error: unknown) => deps.worktreeFailed?.(error instanceof Error ? error.message : String(error), text));
  }
  return {
    onAsk(harness, text, picked, model, environment) {
      remember(harness);
      if (environment) return startInEnvironment(harness, text, model, environment);
      deps.leave();
      // The prompt goes in the same turn as the switch: the switch queues it, and a folder trust
      // refusal then holds it with the send's gesture (holdPrompt), so Trust sends it. Sending
      // after `chat.new` settled lost it: the switch had stopped on the refusal with nothing
      // queued ("Not sent").
      const start = (folder?: string) => {
        ignore(callNative("chat.new", { harness, ...(folder ? { cwd: folder } : {}), ...(model ? { model } : {}) }));
        if (text) ignore(callNative("chat.send", { text }));
      };
      // The page seeds its project with the inherited folder (`~` in a fresh workspace): that is no
      // pick, so the chat starts in its start folder (the host named it). A real pick goes through
      // the host first (cx-nn3e).
      if (picked && picked !== cwd) {
        if (deps.requestFolder) deps.requestFolder(picked, start);
        else start(picked);
      } else start(deps.chatCwd);
    },
    environments: environmentHost(callNative),
    onConnect: (kind) =>
      ignore(callNative("action.run", { id: kind === "ssh" ? "remote.connect" : "newCloudMachine" })),
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
    onTouched: () => ignore(callNative("newTab.touched")),
    // Labs (team builds): the app saves the toggle and answers with a new `data-labs`.
    onSetLab: (flag, on) => ignore(callNative("newTab.setLab", { flag, on })),
    onShowLabs: () => ignore(callNative("action.run", { id: "help.featureFlags" })),
    // A blank terminal in the tab's folder (nothing typed), or a browser tab on the new tab page.
    onCreate: (kind) =>
      ignore(
        callNative(
          "tab.open",
          kind === "terminal" ? { kind, text: "", run: false, ...(cwd ? { cwd } : {}) } : { kind, text: "" },
        ),
      ),
    onInputReady: (token) => ignore(callNative("newTab.inputReady", { token })),
  };
}
