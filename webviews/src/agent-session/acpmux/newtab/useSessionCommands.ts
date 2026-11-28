import { useEffect, useState } from "react";
import type { SlashCommand } from "../slashCommands";

/// Watches a session's command list: calls the listener on each new list, returns the unsubscribe.
export type WatchSessionCommands = (sessionId: string, listener: () => void) => () => void;

/** A deferred session publishes commands after creation. Re-read on its metadata updates and on each
 * list it publishes (`watch`), without attaching it: the first read can come before the agent answered,
 * and a deferred chat's metadata may never change after that. */
export function useSessionCommands(
  sessionId: string | undefined,
  revision: object | undefined,
  read: (sessionId: string) => Promise<SlashCommand[]>,
  watch?: WatchSessionCommands,
) {
  const [loaded, setLoaded] = useState<{ sessionId: string; commands: SlashCommand[] }>();
  const [published, setPublished] = useState(0);
  // Subscribed before the read below starts: a list published while that read is in flight reads again.
  useEffect(() => {
    if (!sessionId || !watch) return;
    return watch(sessionId, () => setPublished((count) => count + 1));
  }, [sessionId, watch]);
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
  }, [sessionId, revision, read, published]);
  return loaded?.sessionId === sessionId ? loaded?.commands : undefined;
}
