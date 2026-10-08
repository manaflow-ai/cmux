import { useCallback, useEffect, useRef, useState } from "react";
import { readFolderTrust, sessionTrust, type TrustLevel, type TrustSource } from "./folderTrust";
import type { StringKey } from "./i18n";
import { isTrustRefusal } from "./direct";

/// The chat's trust question: "ask" while the folder reads as unknown for the chat's agent, then
/// the user's answer with its Undo, or "failed" when saving it didn't.
export type FolderTrustAsk =
  | { cwd: string; state: "ask" | "failed" | "remote" }
  | { cwd: string; state: "decided"; level: Exclude<TrustLevel, "unknown"> };

/// Why Send is off; no `reason` while the folder's trust is still being read.
export type SendBlock = { reason?: StringKey };

/// The trust question for the chat in `cwd`, asked as soon as the folder is known (a new chat
/// before its first prompt). No prompt goes while it is open or after Don't trust: `blocked`
/// says why, and acpmux refuses the prompt too (`trust_gate.rs`). Another chat or folder asks
/// again; Trust's answer goes once the user sends their next prompt (`prompts` grows), and
/// Don't trust's stays with its Undo.
///
/// A refusal for a folder the pane did not know (a new chat whose folder the host filled in)
/// asks about the folder acpmux named (`refused`), and Trust then sends the held prompt again
/// (one gesture); Don't trust leaves it in the composer with the reason.
export function useFolderTrustAsk(
  source: TrustSource,
  chat: { sessionId?: string; cwd?: string; family?: string; prompts: number },
  canAnswer = true,
) {
  const [ask, setAsk] = useState<FolderTrustAsk>();
  const [reading, setReading] = useState(false);
  /// Bumped by `recheck` (acpmux refused a prompt the pane did not hold): read the folder again.
  const [reads, setReads] = useState(0);
  /// The folder acpmux named in a trust refusal for this chat, and the prompt to send after Trust.
  const [refusal, setRefusal] = useState<{ sessionId?: string; cwd?: string }>();
  const resend = useRef<(() => void) | undefined>(undefined);
  const { sessionId, family, prompts } = chat;
  const cwd = chat.cwd ?? (refusal && refusal.sessionId === sessionId ? refusal.cwd : undefined);
  // The chat a reply belongs to; a late reply for another one is dropped.
  const current = useRef({ sessionId, cwd });
  current.current = { sessionId, cwd };
  const decidedAt = useRef<number | undefined>(undefined);
  // One answer at a time: a second click while the first saves is ignored.
  const saving = useRef(false);

  useEffect(() => {
    setAsk(undefined);
    decidedAt.current = undefined;
    setReading(Boolean(cwd));
    if (!cwd) return;
    let live = true;
    void readFolderTrust(source, cwd).then((trust) => {
      if (!live) return;
      setReading(false);
      // A folder the pane can't read is not asked about; acpmux still refuses its prompts.
      const level = trust && sessionTrust(trust, family);
      if (level === "unknown") setAsk({ cwd, state: canAnswer ? "ask" : "remote" });
      else if (level === "untrusted") setAsk({ cwd, state: "decided", level });
    });
    return () => {
      live = false;
    };
  }, [source, sessionId, cwd, family, reads, canAnswer]);

  useEffect(() => {
    if (
      ask?.state === "decided" &&
      ask.level === "trusted" &&
      decidedAt.current !== undefined &&
      prompts > decidedAt.current
    )
      setAsk(undefined);
  }, [ask, prompts]);

  const save = useCallback(
    async (level: TrustLevel) => {
      if (!ask || saving.current) return;
      saving.current = true;
      const asked = { sessionId, cwd: ask.cwd };
      const stillHere = () => current.current.sessionId === asked.sessionId && current.current.cwd === asked.cwd;
      try {
        await source.set(asked.cwd, level);
        if (!stillHere()) return;
        decidedAt.current = level === "unknown" ? undefined : prompts;
        setAsk(level === "unknown" ? { cwd: asked.cwd, state: "ask" } : { cwd: asked.cwd, state: "decided", level });
        // The prompt acpmux refused goes now that the folder is trusted; another answer keeps it.
        const held = resend.current;
        resend.current = undefined;
        if (level === "trusted") held?.();
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      } finally {
        saving.current = false;
      }
    },
    [ask, source, sessionId, prompts],
  );

  const blocked: SendBlock | undefined = reading
    ? {}
    : ask?.state === "ask" || ask?.state === "failed"
      ? { reason: "trust.answerFirst" }
      : ask?.state === "remote"
        ? { reason: "trust.remote" }
        : ask?.state === "decided" && ask.level === "untrusted"
          ? { reason: "trust.untrustedNoPrompts" }
          : undefined;

  return {
    ask,
    blocked,
    trust: () => void save("trusted"),
    distrust: () => void save("untrusted"),
    /// Back to unknown: acpmux forgets its record and each agent's own level answers.
    undo: () => void save("unknown"),
    /// Takes a refusal from acpmux: for its folder trust it reads the folder it named again (the
    /// question shows), keeps `again` to send after Trust, and is true; any other refusal is false.
    refused: useCallback(
      (error: unknown, again?: () => void): boolean => {
        if (!isTrustRefusal(error)) return false;
        const named = (error as { cwd?: unknown }).cwd;
        if (typeof named === "string" && named) setRefusal({ sessionId, cwd: named });
        resend.current = again;
        setReads((count) => count + 1);
        return true;
      },
      [sessionId],
    ),
  };
}
