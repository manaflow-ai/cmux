import { useEffect, useState } from "react";
import type { SlashCommand } from "../slashCommands";

/** A deferred session publishes commands after creation. Re-read on its metadata updates without attaching it. */
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
      () => undefined,
    );
    return () => {
      current = false;
    };
  }, [sessionId, revision, read]);
  return loaded?.sessionId === sessionId ? loaded?.commands : undefined;
}
