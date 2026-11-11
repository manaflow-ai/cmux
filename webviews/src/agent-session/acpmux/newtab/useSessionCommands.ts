import { useEffect, useState } from "react";
import type { AcpmuxSnapshot } from "../model";
import type { SlashCommand } from "../slashCommands";

/** A deferred session publishes commands after creation. Re-read on its metadata updates without attaching it.
 *  undefined until the session's list is read; a read that fails counts as read empty, so the `/` menu
 *  never says "Loading commands…" for a list that cannot come. */
export function useSessionCommands(
  sessionId: string | undefined,
  revision: object | undefined,
  read: (sessionId: string) => Promise<SlashCommand[]>,
) {
  const [loaded, setLoaded] = useState<{ sessionId: string; commands: SlashCommand[] }>();
  useEffect(() => {
    if (!sessionId) return;
    let current = true;
    void read(sessionId).then(
      (commands) => current && setLoaded({ sessionId, commands }),
      () => current && setLoaded((last) => (last?.sessionId === sessionId ? last : { sessionId, commands: [] })),
    );
    return () => {
      current = false;
    };
  }, [sessionId, revision, read]);
  return loaded?.sessionId === sessionId ? loaded?.commands : undefined;
}

/// The snapshot New Tab draws its `/` menu from (M7). `commandSession`: the deferred chat New Tab
/// started for its harness's commands, `commands` that chat's list once read (useSessionCommands).
/// `asked`: New Tab asked for that chat and it is not known yet. Not read yet (either way) is
/// `commandsPending`, so the menu says "Loading commands…", not "No commands"; a read list is the
/// menu's own, empty or not.
export function newTabCommandSnapshot(
  snapshot: AcpmuxSnapshot,
  commandSession: string | undefined,
  commands: SlashCommand[] | undefined,
  asked: boolean,
): AcpmuxSnapshot {
  if (commandSession) {
    const shown: AcpmuxSnapshot = { ...snapshot, commands: commands ?? [] };
    if (commands) delete shown.commandsPending;
    else shown.commandsPending = true;
    return shown;
  }
  return asked && !snapshot.commandsPending ? { ...snapshot, commandsPending: true } : snapshot;
}
