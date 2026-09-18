import { useCallback, useEffect, useRef, useState } from "react";
import { canStartProvider, sendInput, startProvider, type Action, type SessionState } from "../shared/sessionModel";

type Submission = Parameters<typeof sendInput>[2];
type PendingSubmission = {
  options: Submission;
  providerId: SessionState["selectedProviderId"];
  phase: "waiting" | "sending";
  onSent: () => void;
};

/** Owns one submission through startup and the native acknowledgement. */
export function useSessionSubmission(state: SessionState, dispatch: React.Dispatch<Action>) {
  const pending = useRef<PendingSubmission | null>(null);
  const [isPending, setIsPending] = useState(false);

  const finish = useCallback((request: PendingSubmission) => {
    if (pending.current !== request) return;
    pending.current = null;
    setIsPending(false);
  }, []);
  const send = useCallback((request: PendingSubmission) => {
    request.phase = "sending";
    void sendInput(state, dispatch, request.options).then((didSend) => {
      if (didSend) request.onSent();
      finish(request);
    });
  }, [state, dispatch, finish]);

  useEffect(() => {
    const request = pending.current;
    if (!request) return;
    if (request.providerId !== state.selectedProviderId || state.status === "stopping" || state.status === "failed") {
      finish(request);
    } else if (request.phase === "waiting" && state.status === "running" && state.runningSessionId) {
      send(request);
    }
  }, [state, finish, send]);

  const canSubmit = !isPending && !state.isTurnActive && (
    (state.status === "running" && Boolean(state.runningSessionId)) ||
    (state.context?.renderer === "guiMode" && (canStartProvider(state) || state.status === "starting"))
  );

  return {
    canSubmit,
    isPending,
    submit(options: Submission, onSent: () => void = () => {}) {
      // The ref also gates multiple key events before React commits a render.
      if (pending.current || !canSubmit) return false;
      const request: PendingSubmission = { options, onSent, providerId: state.selectedProviderId, phase: "waiting" };
      pending.current = request;
      setIsPending(true);
      if (state.status === "running" && state.runningSessionId) {
        send(request);
      } else if (canStartProvider(state)) {
        void startProvider(state, dispatch, options);
      }
      return true;
    },
  };
}
