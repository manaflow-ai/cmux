import { useT } from "./i18n";
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

const code = (error: unknown) =>
  typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;

/// The user picked `cwd` for a chat. A folder the host takes is passed to `use` (as the host
/// spells it); one that needs the user's answer comes back as the question to show, and nothing
/// is used. A host that predates the question (`unsupported`) uses the folder as before.
export async function pickFolder(callNative: Native, cwd: string, use: (cwd: string) => void): Promise<FolderAsk | undefined> {
  let reply: unknown;
  try {
    reply = await callNative("workspace.useFolder", { cwd });
  } catch (error) {
    if (code(error) !== "unsupported") throw error;
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
  onUse,
  onCancel,
}: {
  ask: FolderAsk;
  /// The chat's start folder now, when it has one (else it starts in the private folder).
  current?: string;
  error?: string;
  onUse(): void;
  onCancel(): void;
}) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-start-folder-ask" aria-live="polite">
      {ask.reason === "home" ? t("startFolder.homeQuestion") : t("startFolder.root", { folder: ask.cwd })}{" "}
      {ask.reason === "home" && (
        <button type="button" className="acpmux-folder-choice-button" onClick={onUse}>
          {t("startFolder.useHome")}
        </button>
      )}{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onCancel}>
        {current && !isAgentHome(current) ? t("startFolder.keep", { folder: projectLabel(current) }) : t("startFolder.usePrivate")}
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
