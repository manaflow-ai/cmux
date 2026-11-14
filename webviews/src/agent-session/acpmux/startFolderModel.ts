import { translate } from "./i18n";
import { rememberWorktreeSetup, type WorktreeSetupStart } from "./worktreeSetupStore";
import { isStartableProject } from "./newtab/startedProject";

// Where a chat starts (cx-nn3e). The host names a new chat's folder in the handshake (its
// workspace's folder, else none: the chat starts in the workspace's private agent-home folder),
// and the pane keeps that one value as the chat's start folder: the folder chip shows it and every
// start sends it. A folder the user picks goes through the host first (`workspace.useFolder`):
// a project folder is used at once; the home folder is asked about once, above the composer,
// before any chat starts there; `/` and the folders above the home folder are refused.

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// What a pane's new chat starts with (``newChatFolder``): `inherited` is the tab's own folder (a
/// fresh workspace's tab sits at `~`), `startFolder` the chat's start folder (the host's, or a pick
/// the host took), `fresh` whether no chat is shown yet.
export type NewChatFolderInputs = {
  cwd?: string;
  inherited?: string;
  startFolder?: string;
  fresh: boolean;
};

/// The folder a new chat starts in, for every start the pane makes (`chat.new`: the agent row, a
/// harness or model pick in the chips, the slash command list, Enter, a page script), and every
/// agent alike (decision 1 above; cmux#40938). The folder the caller names, unless that is only the
/// tab's inherited folder and no project (`~` or above, agent-home: isStartableProject); else the
/// chat's start folder. The inherited folder is a terminal's folder:
/// a chat never starts there by itself, so a tab at `~` never makes a chat start in the home folder,
/// which the relay refuses until the person answered the home question ("This folder is outside the
/// folders this pane may use"). Once they did, `~` is the start folder and is used.
/// `null`: the new chat has no folder; the host fills it (the workspace's folder, else its private
/// agent-home folder), never the folder of an earlier start. `undefined`: a shown chat's switch,
/// which keeps that chat's folder (harnessSwitch.ts).
export function newChatFolder({ cwd, inherited, startFolder, fresh }: NewChatFolderInputs): string | null | undefined {
  if (cwd && (cwd !== inherited || cwd === startFolder || isStartableProject(cwd))) return cwd;
  return fresh ? (startFolder ?? null) : undefined;
}

/// A picked folder that waits for the user: `home` asks (Use Home Folder), `root` is refused.
export type FolderAsk = { cwd: string; reason: "home" | "root" };

type Answer = { status?: unknown; reason?: unknown; cwd?: unknown };

function read(reply: unknown, cwd: string): { status: string; reason?: string; cwd: string } {
  const answer = (reply ?? {}) as Answer;
  return {
    status: typeof answer.status === "string" ? answer.status : "ok",
    ...(typeof answer.reason === "string" ? { reason: answer.reason } : {}),
    cwd: typeof answer.cwd === "string" && answer.cwd ? answer.cwd : cwd,
  };
}

/// The user picked `cwd` for a chat. A folder the host takes is passed to `use` (as the host
/// spells it); one that needs the user's answer comes back as the question to show, and nothing
/// is used, as for a path the host says is no folder. A host that cannot answer (one that predates
/// the question, the browser dev page) uses the folder as before: the question is the pane's
/// courtesy, and the relay still refuses the home folder until the user answered it
/// (AcpmuxPathPolicy).
export async function pickFolder(
  callNative: Native,
  cwd: string,
  use: (cwd: string) => void,
  refused?: (error: unknown) => void,
): Promise<FolderAsk | undefined> {
  let reply: unknown;
  try {
    reply = await callNative("workspace.useFolder", { cwd });
  } catch (error) {
    // The host's own refusal of the path (not a folder) uses nothing.
    if (
      typeof error === "object" &&
      error !== null &&
      (error as { code?: unknown }).code === "transport.path_invalid"
    ) {
      refused?.(error);
      return undefined;
    }
    use(cwd);
    return undefined;
  }
  const answer = read(reply, cwd);
  if (answer.status === "ok") {
    use(answer.cwd);
    return undefined;
  }
  return { cwd: answer.cwd, reason: answer.status === "confirm" && answer.reason === "home" ? "home" : "root" };
}

/// New Worktree (cx-lyqio.2, Codex/Conductor style): the host makes a worktree of the new chat's
/// folder on a branch of its own (`git.worktree.create`, on this click; the user's checkout stays
/// as it is), and the chat starts there as in a picked folder: when the host asks about that
/// folder first, the question comes back (`ask`) for the pane to show, and nothing starts until the
/// user answers it. Rejects with the host's reason when it makes none; nothing is used then.
/// The host starts the project's worktree recipe after its reply (`setup`): the pane remembers it
/// before the chat uses the folder, so the chat's setup line (worktreeSetup.tsx) follows it at once.
export async function newWorktree(
  callNative: Native,
  cwd: string,
  use: (cwd: string) => void,
): Promise<{ root: string; branch?: string; ask?: FolderAsk; setup?: WorktreeSetupStart }> {
  let reply: { value?: { root?: unknown; branch?: unknown; setup?: unknown } } | undefined;
  try {
    reply = (await callNative("git.worktree.create", { cwd, idempotency_key: crypto.randomUUID() })) as typeof reply;
  } catch (error) {
    // The session host's own words (`details.extra.message`: a base that names nothing, not a
    // repository) say more than the pane's generic failure.
    const details = (error as { details?: { extra?: { message?: unknown } } } | null)?.details;
    const reason = details?.extra?.message;
    throw typeof reason === "string" && reason ? new Error(reason) : error;
  }
  const root = reply?.value?.root;
  if (typeof root !== "string" || !root) throw new Error(translate("worktree.failed"));
  const setup = rememberWorktreeSetup(root, reply?.value?.setup);
  // The host may spell the folder its own way (links resolved): the line follows that spelling too.
  const ask = await pickFolder(callNative, root, (folder) => {
    if (setup && folder !== root) rememberWorktreeSetup(folder, setup);
    use(folder);
  });
  const branch = reply?.value?.branch;
  return {
    root,
    ...(typeof branch === "string" ? { branch } : {}),
    ...(ask ? { ask } : {}),
    ...(setup ? { setup } : {}),
  };
}

/// A new chat in `folder`, a worktree New Worktree made, for a chat that started while it was being
/// made (that chat keeps its own folder). A Cloud or SSH chat's worktree is that machine's folder:
/// the new chat starts there too (`chat.newHere`), never on this Mac in a same-named path.
export function newChatInWorktree(callNative: Native, folder: string, remote: boolean): Promise<unknown> {
  return remote ? callNative("chat.newHere", { cwd: folder }) : callNative("chat.new", { cwd: folder });
}

/// Use Home Folder: the answer goes to the host from this click (it spends the click's gesture
/// and makes the folder a root), then the folder is used at once, so the chat starts there with no
/// Retry. Rejects when the host refuses; nothing is used then.
export async function confirmFolder(callNative: Native, ask: FolderAsk, use: (cwd: string) => void): Promise<void> {
  const answer = read(await callNative("workspace.useFolder", { cwd: ask.cwd, confirm: true }), ask.cwd);
  if (answer.status !== "ok") throw Object.assign(new Error(answer.status), { code: `folder.${answer.status}` });
  use(answer.cwd);
}
