import { useCallback, useEffect, useRef, useState } from "react";
import { readFolderTrust, type TrustLevel, type TrustSource } from "./folderTrust";

/// The chat's trust question, asked without stopping anything: "ask" while acpmux reads the
/// folder as unknown, then the user's answer with its Undo, or "failed" when saving it didn't.
export type FolderTrustAsk =
  | { cwd: string; state: "ask" | "failed" }
  | { cwd: string; state: "decided"; level: Exclude<TrustLevel, "unknown"> };

/// The trust question for the chat in `cwd`, once `started` (its first prompt went): the send is
/// never held for it. Another chat or folder drops the question, and a decided one goes once
/// the user sends their next prompt (`prompts` grows).
export function useFolderTrustAsk(
  source: TrustSource,
  chat: { sessionId?: string; cwd?: string; started: boolean; prompts: number },
) {
  const [ask, setAsk] = useState<FolderTrustAsk>();
  const { sessionId, cwd, started, prompts } = chat;
  // The chat a reply belongs to; a late reply for another one is dropped.
  const current = useRef({ sessionId, cwd });
  current.current = { sessionId, cwd };
  const decidedAt = useRef<number | undefined>(undefined);
  // One answer at a time: a second click while the first saves is ignored.
  const saving = useRef(false);

  useEffect(() => {
    setAsk(undefined);
    decidedAt.current = undefined;
    if (!cwd || !started) return;
    let live = true;
    void readFolderTrust(source, cwd).then((trust) => {
      if (live && trust?.level === "unknown") setAsk({ cwd, state: "ask" });
    });
    return () => {
      live = false;
    };
  }, [source, sessionId, cwd, started]);

  useEffect(() => {
    if (ask?.state === "decided" && decidedAt.current !== undefined && prompts > decidedAt.current) setAsk(undefined);
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
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      } finally {
        saving.current = false;
      }
    },
    [ask, source, sessionId, prompts],
  );

  return {
    ask,
    trust: () => void save("trusted"),
    distrust: () => void save("untrusted"),
    /// Back to unknown: acpmux forgets its record and each agent's own default applies.
    undo: () => void save("unknown"),
  };
}
