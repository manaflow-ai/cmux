import { useCallback, useEffect, useState } from "react";
import type { AcpmuxSnapshot } from "../model";
import type { SlashCommand } from "../slashCommands";

/** A deferred session's command list as New Tab reads it (useSessionCommands). */
export type SessionCommands = {
  /** The session's list once read; undefined before, and after a read that failed. */
  commands: SlashCommand[] | undefined;
  /** The read failed: the `/` menu says it couldn't load the commands, with Try Again. */
  failed: boolean;
  /** Try Again: reads the list again (loading shows meanwhile). */
  retry(): void;
};

/** A deferred session publishes commands after creation. Re-read on its metadata updates without attaching it.
 *  `commands` is undefined until the session's list is read. A read that fails is a failure, not an
 *  empty list (`failed`, with `retry`): the `/` menu never says "No commands" for a list it could not
 *  read, nor "Loading commands…" for good. A list read before stays when a later re-read fails. */
export function useSessionCommands(
  sessionId: string | undefined,
  revision: object | undefined,
  read: (sessionId: string) => Promise<SlashCommand[]>,
): SessionCommands {
  const [loaded, setLoaded] = useState<{ sessionId: string; commands?: SlashCommand[]; failed?: true }>();
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!sessionId) return;
    let current = true;
    void read(sessionId).then(
      (commands) => current && setLoaded({ sessionId, commands }),
      () =>
        current &&
        setLoaded((last) => (last?.sessionId === sessionId && last.commands ? last : { sessionId, failed: true })),
    );
    return () => {
      current = false;
    };
  }, [sessionId, revision, read, attempt]);
  const retry = useCallback(() => {
    setLoaded((last) => (last?.failed ? undefined : last));
    setAttempt((count) => count + 1);
  }, []);
  const mine = loaded?.sessionId === sessionId ? loaded : undefined;
  return { commands: mine?.commands, failed: Boolean(mine?.failed), retry };
}

/// How New Tab's ask for a deferred chat (`chat.new` deferred) stands on this page: asked and the
/// chat not known yet, or refused (a failure with Try Again, never the page's empty list).
export type NewTabCommandAsk = "asked" | "failed" | undefined;

/// The snapshot New Tab draws its `/` menu from (M7). `commandSession`: the deferred chat New Tab
/// started for its harness's commands, `read` that chat's list (useSessionCommands). `ask`: New Tab
/// asked for that chat and it is not known yet, or the ask was refused. Not read yet (either way)
/// is `commandsPending`, so the menu says "Loading commands…"; a read or an ask that failed is
/// `commandsFailed` ("Couldn't load commands." with Try Again), never "No commands"; a read list is
/// the menu's own, empty or not.
export function newTabCommandSnapshot(
  snapshot: AcpmuxSnapshot,
  commandSession: string | undefined,
  read: Pick<SessionCommands, "commands" | "failed">,
  ask: NewTabCommandAsk,
): AcpmuxSnapshot {
  if (commandSession) {
    const shown: AcpmuxSnapshot = { ...snapshot, commands: read.commands ?? [] };
    delete shown.commandsPending;
    delete shown.commandsFailed;
    if (!read.commands) {
      if (read.failed) shown.commandsFailed = true;
      else shown.commandsPending = true;
    }
    return shown;
  }
  if (ask === "failed") {
    const shown: AcpmuxSnapshot = { ...snapshot, commandsFailed: true };
    delete shown.commandsPending;
    return shown;
  }
  return ask === "asked" && !snapshot.commandsPending ? { ...snapshot, commandsPending: true } : snapshot;
}
