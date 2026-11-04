// A Stop pressed while the pane cannot reach acpmux is kept, not dropped. acpmux restarts on a new
// version mid-turn and resumes what it interrupted, and while the pane reconnects its Stop went
// nowhere: the client refuses a cancel on a closed socket (`direct.ts` `cancel`), the page's actions
// are gone until the next client connects, and the composer let the refusal go unseen. The turn
// went on as if Stop had never been pressed (Leo, 2026-10-29: "i literally can't stop you i clicked
// the stop button and it didnt do anything"). Now the composer says it is stopping, and the Stop
// goes out once the pane is connected to that chat again and that same turn runs: the turn acpmux
// resumed, or its automatic continuation (`P~resume-n` runs for `P`, direct.ts `promptRoot`).
// `session/cancel` stops whatever the chat runs, so a kept Stop never goes to another turn (a
// queued prompt that started meanwhile) and never goes while nothing runs.
import { useCallback, useEffect, useRef, useState } from "react";

/// What the kept Stop reads of the pane: the chat it shows, its connection (the snapshot's
/// `connection`, which also carries what a snapshot was emitted for: an event's kind, `history`),
/// whether it works and the prompt of the turn that runs (snapshot `turnPrompt`).
export type StopView = { sessionId?: string; connection: string; isWorking: boolean; turnPrompt?: string };

/// A Stop acpmux did not get: the chat and the turn (by its prompt) it was for, and whether the
/// pane must lose its connection before sending it again (it was refused while the pane still read
/// connected: the socket was closing, and a send now would be refused the same way).
export type KeptStop = { sessionId: string; turnPrompt?: string; awaitsDisconnect: boolean };

/// The pane reaches acpmux: any snapshot but a lost, opening or retrying connection's (App.tsx
/// `connected`, model.ts `connectionStatus`).
const reachable = (connection: string) =>
  connection !== "disconnected" && connection !== "reconnecting" && !connection.startsWith("connecting");

/// What to do with `kept` now. `keep`: wait (with `awaitsDisconnect` cleared once the pane read a
/// lost connection); `send`: the pane is connected to that chat again and the stopped turn runs;
/// `drop`: another chat shows, another turn runs, or the stopped turn ended while the pane stayed
/// connected.
export function keptStopStep(kept: KeptStop, view: StopView): { step: "keep" | "send" | "drop"; kept: KeptStop } {
  if (view.sessionId !== kept.sessionId) return { step: "drop", kept };
  if (!reachable(view.connection))
    return { step: "keep", kept: kept.awaitsDisconnect ? { ...kept, awaitsDisconnect: false } : kept };
  // Another turn runs (a prompt that waited, or one sent since), or one this pane cannot name: only
  // the stopped turn itself, known by its prompt, takes the session-wide cancel.
  if (view.isWorking && (!kept.turnPrompt || view.turnPrompt !== kept.turnPrompt)) return { step: "drop", kept };
  if (kept.awaitsDisconnect) return { step: view.isWorking ? "keep" : "drop", kept };
  // Back with nothing running: the stopped turn's continuation may still start (acpmux resumes it
  // after a wait), and the Stop goes then; a different turn starting drops it (above).
  if (!view.isWorking) return { step: "keep", kept };
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
  const keepRefused = useCallback((pressed: StopView) => {
    const now = latest.current.view;
    if (!pressed.sessionId || now.sessionId !== pressed.sessionId) return;
    setKept({
      sessionId: pressed.sessionId,
      turnPrompt: pressed.turnPrompt,
      awaitsDisconnect: reachable(now.connection),
    });
  }, []);
  const stop = useCallback(() => {
    const pressed = latest.current.view;
    latest.current.cancel().catch(() => keepRefused(pressed));
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
        keepRefused({ ...latest.current.view, sessionId: kept.sessionId, turnPrompt: kept.turnPrompt });
      });
  }, [kept, step, nextKept, keepRefused]);
  return { stop, stopping: step === "keep" && view.isWorking };
}
