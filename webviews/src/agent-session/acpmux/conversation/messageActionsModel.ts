/// A hover row's glyph size: Claude's 16 px icons, each in a 24 px (--cv-meta-row) button.
export const ROW_ICON = 16;

/// Use the live host action when the page has one: unlike the turn context's legacy callback, it
/// returns the fork promise so the button can stay pending until the new agent is ready. Gallery
/// and unit-test callers keep their injected fallback.
export function forkWithFeedback(throughSeq: number, fallback: () => unknown): unknown {
  const action = globalThis.window?.cmuxAcpmuxActions?.["chat.fork"];
  if (!action) return fallback();
  return action({ throughSeq }).then((sessionId) => {
    // direct.fork reports refusal by returning no session id after it has written the localized
    // transcript notice; turn that sentinel into the button's terminal error state too.
    // l10n-allow: the button's error state only; the transcript notice already says why.
    if (sessionId === undefined || sessionId === null || sessionId === false) throw new Error("fork failed");
    return sessionId;
  });
}
