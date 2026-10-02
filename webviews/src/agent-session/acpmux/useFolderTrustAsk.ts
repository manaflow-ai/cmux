import { useCallback, useEffect, useRef, useState } from "react";
import { readFolderTrust, type TrustLevel, type TrustSource } from "./folderTrust";

/// The chat's trust question, asked without stopping anything: "ask" while acpmux reads the
/// folder as unknown, then the user's answer with its Undo, or "failed" when saving it didn't.
export type FolderTrustAsk =
  | { cwd: string; state: "ask" | "failed" }
  | { cwd: string; state: "decided"; level: Exclude<TrustLevel, "unknown"> };

/// The trust question for the chat in `cwd`, once `started` (its first prompt went): the send is
/// never held for it. Another chat or folder drops the question, and a decided one goes once
/// the next prompt starts (`turns` grows).
export function useFolderTrustAsk(
  source: TrustSource,
  chat: { sessionId?: string; cwd?: string; started: boolean; turns: number },
) {
  const [ask, setAsk] = useState<FolderTrustAsk>();
  const { sessionId, cwd, started, turns } = chat;
  // The chat a reply belongs to; a late reply for another one is dropped.
  const current = useRef({ sessionId, cwd });
  current.current = { sessionId, cwd };
  const decidedAt = useRef<number | undefined>(undefined);

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
    if (ask?.state === "decided" && decidedAt.current !== undefined && turns > decidedAt.current) setAsk(undefined);
  }, [ask, turns]);

  const save = useCallback(
    async (level: TrustLevel) => {
      if (!ask) return;
      const asked = { sessionId, cwd: ask.cwd };
      const stillHere = () => current.current.sessionId === asked.sessionId && current.current.cwd === asked.cwd;
      try {
        await source.set(asked.cwd, level);
        if (!stillHere()) return;
        decidedAt.current = level === "unknown" ? undefined : turns;
        setAsk(level === "unknown" ? { cwd: asked.cwd, state: "ask" } : { cwd: asked.cwd, state: "decided", level });
      } catch {
        if (stillHere()) setAsk({ cwd: asked.cwd, state: "failed" });
      }
    },
    [ask, source, sessionId, turns],
  );

  return {
    ask,
    trust: () => void save("trusted"),
    distrust: () => void save("untrusted"),
    /// Back to unknown: acpmux forgets its record and each agent's own default applies.
    undo: () => void save("unknown"),
  };
}
