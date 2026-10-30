// A Stop pressed while the pane cannot reach acpmux is kept, not dropped. acpmux restarts on a new
// version mid-turn and resumes what it interrupted, and while the pane reconnects its Stop went
// nowhere: the client refuses a cancel on a closed socket (`direct.ts` `cancel`), the page's actions
// are gone until the next client connects, and the composer let the refusal go unseen. The turn
// went on as if Stop had never been pressed (Leo, 2026-10-29: "i literally can't stop you i clicked
// the stop button and it didnt do anything"). Now the composer says it is stopping, and the Stop
// goes out once the pane is connected to that chat again: it stops the turn acpmux resumed, or the
// retry of it still waiting (acpmux's Stop withdraws that too, `hub/cancel.rs`).
import { useCallback, useEffect, useRef, useState } from "react";

/// What the kept Stop reads of the pane: the chat it shows, its connection and whether it works.
export type StopView = { sessionId?: string; connection: string; isWorking: boolean };

/// A Stop acpmux did not get: the chat it was for, and whether the pane must lose its connection
/// before sending it again (it was refused while the pane still read connected: the socket was
/// closing, and a send now would be refused the same way).
export type KeptStop = { sessionId: string; awaitsDisconnect: boolean };

/// What to do with `kept` now. `keep`: wait (with `awaitsDisconnect` cleared once the pane read a
/// lost connection); `send`: the pane is connected to that chat again; `drop`: another chat shows,
/// or the chat stopped working while the pane stayed connected.
export function keptStopStep(kept: KeptStop, view: StopView): { step: "keep" | "send" | "drop"; kept: KeptStop } {
  if (view.sessionId !== kept.sessionId) return { step: "drop", kept };
  if (view.connection !== "connected")
    return { step: "keep", kept: kept.awaitsDisconnect ? { ...kept, awaitsDisconnect: false } : kept };
  if (kept.awaitsDisconnect) return { step: view.isWorking ? "keep" : "drop", kept };
  return { step: "send", kept };
}

/// The composer's Stop: `cancel` now, and when it is refused, the kept Stop above. `stopping` says
/// the composer shows the chat stopping meanwhile.
export function useStopThroughReconnect(
  view: StopView,
  cancel: () => Promise<unknown>,
): { stop: () => void; stopping: boolean } {
  const [kept, setKept] = useState<KeptStop>();
  const latest = useRef({ view, cancel });
  latest.current = { view, cancel };
  const keepRefused = useCallback((sessionId: string) => {
    const now = latest.current.view;
    if (now.sessionId !== sessionId) return;
    setKept({ sessionId, awaitsDisconnect: now.connection === "connected" });
  }, []);
  const stop = useCallback(() => {
    const sessionId = latest.current.view.sessionId;
    latest.current.cancel().catch(() => {
      if (sessionId) keepRefused(sessionId);
    });
  }, [keepRefused]);
  const next = kept ? keptStopStep(kept, view) : undefined;
  const step = next?.step;
  const nextKept = next?.kept;
  useEffect(() => {
    if (!kept || !step) return;
    if (step === "keep") {
      if (nextKept && nextKept !== kept) setKept(nextKept);
      return;
    }
    setKept(undefined);
    if (step === "send")
      latest.current.cancel().catch(() => {
        keepRefused(kept.sessionId);
      });
  }, [kept, step, nextKept, keepRefused]);
  return { stop, stopping: step === "keep" && view.isWorking };
}
