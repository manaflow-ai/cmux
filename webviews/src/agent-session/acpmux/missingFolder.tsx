import { useT } from "./i18n";

// A chat whose folder is missing (cx-nn3e.1): acpmux's `_acpmux/chat_open` said the person must
// pick a folder (the recorded one was deleted or moved, or the chat recorded none). The chat opens
// in its pane with this line above the composer; Choose Folder asks the host (`chat.folder.choose`:
// the native sheet on this pane, then `chat_open` with the pick), and a resumable chat resumes here.

export type AdoptChoice = { harness: string; agentSessionId: string };
type Reply = { adopt?: unknown; cwd?: unknown; reason?: unknown; opened?: unknown } | null | undefined;

function readAdopt(value: unknown): AdoptChoice | undefined {
  const adopt = value as { harness?: unknown; agentSessionId?: unknown } | null | undefined;
  return typeof adopt?.harness === "string" && typeof adopt.agentSessionId === "string"
    ? { harness: adopt.harness, agentSessionId: adopt.agentSessionId }
    : undefined;
}

/// One pick: `done` when the chat resumed here or opened elsewhere, `reason` when the pick still
/// does not work (the line stays with it), nothing when the user cancelled.
export async function chooseChatFolder(
  choose: () => Promise<unknown>,
  resume: (adopt: AdoptChoice) => Promise<unknown>,
): Promise<{ done?: true; reason?: string }> {
  const reply = (await choose()) as Reply;
  const adopt = readAdopt(reply?.adopt);
  if (adopt) {
    await resume(adopt);
    return { done: true };
  }
  if (reply?.opened === true) return { done: true };
  if (typeof reply?.reason === "string" && reply.reason) return { reason: reply.reason };
  return {};
}

/// The line above the composer: why the chat has no folder, acpmux's reason, Choose Folder.
export function MissingFolder({ reason, error, onChoose }: { reason: string; error?: string; onChoose(): void }) {
  const t = useT();
  return (
    <output className="acpmux-switch-notice acpmux-folder-choice acpmux-missing-folder" aria-live="polite">
      {t("missingFolder.notice")} <span className="acpmux-missing-folder-reason">{reason}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={onChoose}>
        {t("agentHome.choose")}
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
