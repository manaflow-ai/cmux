import { translate, useT } from "./i18n";
import { isAgentHome, projectLabel } from "./sessionList";

// Where a chat starts (cx-nn3e). The host names a new chat's folder in the handshake (its
// workspace's folder, else none: the chat starts in the workspace's private agent-home folder),
// and the pane keeps that one value as the chat's start folder: the folder chip shows it and every
// start sends it. A folder the user picks goes through the host first (`workspace.useFolder`):
// a project folder is used at once; the home folder is asked about once, above the composer,
// before any chat starts there; `/` and the folders above the home folder are refused.

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

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
  refused?: () => void,
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
      refused?.();
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
export async function newWorktree(
  callNative: Native,
  cwd: string,
  use: (cwd: string) => void,
): Promise<{ root: string; branch?: string; ask?: FolderAsk }> {
  let reply: { value?: { root?: unknown; branch?: unknown } } | undefined;
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
  const ask = await pickFolder(callNative, root, use);
  const branch = reply?.value?.branch;
  return { root, ...(typeof branch === "string" ? { branch } : {}), ...(ask ? { ask } : {}) };
}

/// New Worktree's refusal above the composer: the host's reason, and Dismiss.
export function WorktreeFailure({ error, onDismiss }: { error: string; onDismiss(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      <span role="alert">{t("worktree.failedBecause", { reason: error })}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
        {t("worktree.dismiss")}
      </button>
    </output>
  );
}

/// Use Home Folder: the answer goes to the host from this click (it spends the click's gesture
/// and makes the folder a root), then the folder is used at once, so the chat starts there with no
/// Retry. Rejects when the host refuses; nothing is used then.
export async function confirmFolder(callNative: Native, ask: FolderAsk, use: (cwd: string) => void): Promise<void> {
  const answer = read(await callNative("workspace.useFolder", { cwd: ask.cwd, confirm: true }), ask.cwd);
  if (answer.status !== "ok") throw Object.assign(new Error(answer.status), { code: `folder.${answer.status}` });
  use(answer.cwd);
}

/// The question above the composer, in the place of the private-folder line: what the home
/// folder means for the agent, Use Home Folder, and the way back (the private folder, or the
/// workspace's folder the chat keeps). `/` gets no Use button. `error` is the host's refusal.
export function StartFolderAsk({
  ask,
  current,
  error,
  confirming,
  onUse,
  onCancel,
}: {
  ask: FolderAsk;
  /// The chat's start folder now, when it has one (else it starts in the private folder).
  current?: string;
  error?: string;
  confirming?: boolean;
  onUse(): void;
  onCancel(): void;
}) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-start-folder-ask" aria-live="polite">
      {ask.reason === "home" ? t("startFolder.homeQuestion") : t("startFolder.root", { folder: ask.cwd })}{" "}
      {ask.reason === "home" && (
        <button type="button" className="acpmux-folder-choice-button" disabled={confirming} onClick={onUse}>
          {t("startFolder.useHome")}
        </button>
      )}{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onCancel}>
        {current && !isAgentHome(current)
          ? t("startFolder.keep", { folder: projectLabel(current) })
          : t("startFolder.usePrivate")}
      </button>
      {error && (
        <>
          {" "}
          <span role="alert">{error}</span>
        </>
      )}
    </output>
  );
}
