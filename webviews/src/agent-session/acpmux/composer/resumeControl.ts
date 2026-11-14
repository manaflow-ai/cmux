import { linkUp, type AcpmuxSnapshot } from "../model";
import { remoteComposer } from "../remoteEditing";
import { runsNext } from "./turnHandover";

export function canResumeFromComposer(
  snapshot: AcpmuxSnapshot,
  state: {
    offered: boolean;
    text: string;
    attachments: number;
    pending: number;
    shell: boolean;
    running: boolean;
    readOnly: boolean;
    blocked: boolean;
    dictating: boolean;
  },
): boolean {
  const goal = snapshot.summary?.goal;
  return (
    state.offered &&
    Boolean(snapshot.sessionId ?? snapshot.summary?.sessionId) &&
    linkUp(snapshot.connection) &&
    remoteComposer(snapshot).canSend &&
    !snapshot.summary?.watching &&
    !state.readOnly &&
    !state.running &&
    !snapshot.isWorking &&
    !runsNext(snapshot.queue, snapshot.summary?.queuePaused === true) &&
    goal?.status !== "running" &&
    goal?.status !== "active" &&
    !state.blocked &&
    !state.shell &&
    !state.dictating &&
    state.text.length === 0 &&
    state.attachments === 0 &&
    state.pending === 0
  );
}
