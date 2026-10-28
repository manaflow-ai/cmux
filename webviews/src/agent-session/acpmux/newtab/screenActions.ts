// The new tab screen's actions as host requests (plans/cmux-next/new-tab.md section 5). An agent
// row starts the chat in this page; everything else asks the host to replace the tab.
import type { AllChatsPage } from "./AllChatsList";
import type { NewTabScreenActions } from "./NewTabScreen";
import { savedEnvironmentHost } from "../environments";
import { rememberStartedProject } from "./startedProject";

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
  /// false: the page's chats run on another machine, whose folders are never this Mac's default.
  startsHere?(): boolean;
}): NewTabScreenActions {
  const { callNative, cwd } = deps;
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  const remember = (agent: string) => ignore(callNative("newTab.remember", { agent }));
  return {
    onAsk(harness, text, picked, model, noProject, attachments, saved) {
      const peer = saved?.peer;
      remember(harness);
      // The prompt goes in the same turn as the switch: the switch queues it, and a folder trust
      // refusal then holds it with the send's gesture (holdPrompt), so Trust sends it. Sending
      // after `chat.new` settled lost it: the switch had stopped on the refusal with nothing
      // queued ("Not sent").
      const start = (folder?: string) => {
        // Keep the New Tab visible while a folder confirmation or worktree request is pending.
        // Leaving before the host accepts the folder briefly mounted the empty chat hero, which
        // read as a flash before the first prompt landed.
        deps.leave();
        // On another machine the prompt waits for its chat: a start that fails there must not
        // send it to a new chat on this Mac.
        if (peer) {
          const send = () =>
            text || attachments?.length
              ? callNative("chat.send", { text, ...(attachments?.length ? { attachments } : {}) })
              : undefined;
          // `chat.new` resolves to the chat it started; none (a refused or held start): no send.
          ignore(
            callNative("chat.new", {
              harness,
              ...(folder ? { cwd: folder } : {}),
              ...(model ? { model } : {}),
              peer,
            }).then((started) => (started ? send() : undefined)),
          );
          return;
        }
        // The person picked this project (or kept the default) and sent: once the chat has started
        // there (`chat.new` resolves to it), the next New Tab starts here (newtab/startedProject.ts).
        // A refused or failed start, no project, or nothing sent leaves the default as it was.
        const remembers = (text || attachments?.length) && deps.startsHere?.() !== false;
        ignore(
          callNative("chat.new", {
            harness,
            ...(folder ? { cwd: folder } : noProject ? { noProject: true } : {}),
            ...(model ? { model } : {}),
          }).then((started) => {
            if (started && remembers) rememberStartedProject(folder, callNative);
          }),
        );
        // Attachments pasted or dropped on the page go with the first prompt, or alone.
        if (attachments?.length) ignore(callNative("chat.send", { text, attachments }));
        else if (text) ignore(callNative("chat.send", { text }));
      };
      // The page seeds its project with the inherited folder (`~` in a fresh workspace): that is no
      // pick, so the chat starts in its start folder (the host named it). A real pick goes through
      // the host first (cx-nn3e).
      // Do not work in a project: no folder at all, so the host starts it in its private folder.
      // A saved SSH environment's folder is the machine's own: this Mac's folder checks don't apply.
      // A saved local one's folder is checked even when it is the tab's own.
      if (noProject) start();
      else if (peer) start(picked);
      else if (picked && (picked !== cwd || saved)) {
        if (deps.requestFolder) deps.requestFolder(picked, start);
        else start(picked);
      } else start(deps.chatCwd);
    },
    savedEnvironments: savedEnvironmentHost(callNative),
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
      deps.selectSession(sessionId);
    },
    // A chat opens in a new workspace (the host's Open Chat path), so this page stays the New
    // Tab page instead of turning into an empty chat.
    onOpenChat: (key) => ignore(callNative("chats.open", { key })),
    onOpenChatInTerminal: (key) => ignore(callNative("chats.openInTerminal", { key })),
    onViewChat: (key) => ignore(callNative("chats.watch", { key })),
    loadChatsPage: (params) => callNative("chats.page", params) as Promise<AllChatsPage | undefined>,
    onShowAll: deps.showAllChats,
    onTouched: () => ignore(callNative("newTab.touched")),
    onNowPlaying: (command) => ignore(callNative("nowPlaying.command", { command })),
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
