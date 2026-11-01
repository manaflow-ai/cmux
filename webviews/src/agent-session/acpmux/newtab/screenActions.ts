// The new tab screen's actions as host requests (plans/cmux-next/new-tab.md section 5). An agent
// row starts the chat in this page; everything else asks the host to replace the tab.
import type { AllChatsPage } from "./AllChatsList";
import type { NewTabScreenActions } from "./NewTabScreen";
import { savedEnvironmentHost } from "../environments";
import { rememberStartedProject } from "./startedProject";
import { rememberPick } from "../lastPick";
import { translate } from "../i18n";

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
  requestFolder?(cwd: string, start: (folder: string) => void, cancel?: () => void): void;
  /// false: the page's chats run on another machine, whose folders are never this Mac's default.
  startsHere?(): boolean;
  /// Captures the page/selection owning this attempt, before any asynchronous work.
  startScope?(allowReconnect: boolean): () => boolean;
}): NewTabScreenActions {
  const { callNative, cwd } = deps;
  const ignore = (result: Promise<unknown>) => void result.catch(() => undefined);
  // The agent a chat starts on is the pick the next New Tab starts on (lastPick.ts): the app's copy
  // and this page's, so an older harness and model picked elsewhere no longer win over it.
  const remember = (agent: string, model: string | undefined, folder: string | undefined) =>
    rememberPick({ harness: agent, ...(model ? { model } : {}) }, folder, callNative);
  return {
    onAsk(harness, text, picked, model, noProject, attachments, saved) {
      const peer = saved?.peer;
      const queuedStart = !!harness && !peer && !noProject;
      const current = deps.startScope?.(queuedStart) ?? (() => true);
      const cancelled = () => new Error(translate("switch.cancelled"));
      // The prompt goes in the same turn as the switch: the switch queues it, and a folder trust
      // refusal then holds it with the send's gesture (holdPrompt), so Trust sends it. Sending
      // after `chat.new` settled lost it: the switch had stopped on the refusal with nothing
      // queued ("Not sent").
      return new Promise<void>((resolve, reject) => {
        const start = (folder?: string) => {
          if (!current()) return reject(cancelled());
          // In the folder the chat starts in, which the next New Tab there reads; a chat on another
          // machine names that machine's agents, so this Mac's new chats keep theirs.
          if (!peer) remember(harness, model, folder);
          // The screen owns its draft and machine pick until the start succeeds. A rejected start
          // must not unmount it; its caller displays the refusal beside the unchanged field.
          const opened = callNative("chat.new", {
            harness,
            ...(folder ? { cwd: folder } : noProject ? { noProject: true } : {}),
            ...(model ? { model } : {}),
            ...(peer ? { peer } : {}),
          });
          const message = { text, ...(attachments?.length ? { attachments } : {}) };
          const asks = !!text || !!attachments?.length;
          if (!queuedStart) {
            opened
              .then(async (started) => {
                if (!current()) throw cancelled();
                if (!started) throw new Error(translate("switch.noSession"));
                if (!peer && asks && deps.startsHere?.() !== false) rememberStartedProject(folder, callNative);
                // The send names this start's session; a later selected chat cannot take it.
                if (asks) {
                  let taken = false;
                  const accepted = () => {
                    if (taken || !current()) return;
                    taken = true;
                    deps.leave();
                  };
                  // Until acpmux takes it, a failed send preflight still belongs to this field.
                  await callNative("chat.send", { ...message, expectedSessionId: started, accepted });
                  accepted();
                } else deps.leave();
              })
              .then(resolve, reject);
            return;
          }
          // Keep the local send in the same turn as the harness switch: its queue owns the prompt
          // while Trust is pending. Awaiting the start before sending would lose that queue.
          const sent = asks ? callNative("chat.send", message) : Promise.resolve();
          // The switch's queue holds the prompt as the chat's first row, "Starting Claude Code…"
          // (harnessSwitch.ts), and hands it back to the chat's composer if the start fails. So the
          // page becomes that chat at once, never after the start: a busy daemon can take a minute
          // and a half to give a harness session (Leo 2026-10-30: "I TSHOULDN'T FUCKING MATTER IF
          // MY COMPUTER IS LOADED" / "I SHOULD BE ALWAYS ABLE TO SATRT NEW FUCKGN CHATS").
          if (asks) deps.leave();
          const accepted = opened.then((started) => {
            if (!current()) throw cancelled();
            if (started) {
              if (asks && deps.startsHere?.() !== false) rememberStartedProject(folder, callNative);
              if (!asks) deps.leave();
            } else if (!asks) throw new Error(translate("switch.noSession"));
          });
          Promise.all([accepted, sent]).then(() => resolve(), reject);
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
          if (deps.requestFolder)
            deps.requestFolder(picked, start, () => reject(new Error(translate("switch.cancelled"))));
          else start(picked);
        } else start(deps.chatCwd);
      });
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
    onAction: (id) => ignore(callNative("app.action", { id })),
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
