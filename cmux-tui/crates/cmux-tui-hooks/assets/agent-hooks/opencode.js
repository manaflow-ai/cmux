const appendEvent = journalPlugin("opencode");
const events = new Set([
  "session.created",
  "session.updated",
  "session.status",
  "session.idle",
  "session.execution.succeeded",
  "session.execution.interrupted",
  "session.execution.failed",
  "session.next.step.failed",
  "session.error",
  "session.compacted",
  "session.deleted",
  "message.updated",
  "tool.execute.before",
  "tool.execute.after",
  "todo.updated",
  "permission.asked",
  "permission.replied",
  "question.asked",
  "question.replied",
  "question.rejected",
]);
const NON_TERMINAL_SESSION_ERRORS = new Set(["MessageAbortedError", "ContextOverflowError"]);
const sessionRoots = new Map();

function topology(event) {
  const properties = event?.data || event?.properties || {};
  const info = properties.info || {};
  const sessionId = info.id || properties.sessionID || properties.sessionId;
  if (!sessionId) return {};
  const parentSessionId = info.parentID || info.parentId || properties.parentID || properties.parentId;
  const rootSessionId = parentSessionId
    ? sessionRoots.get(parentSessionId) || parentSessionId
    : sessionRoots.get(sessionId) || sessionId;
  sessionRoots.set(sessionId, rootSessionId);
  return {
    session_id: sessionId,
    parent_session_id: parentSessionId,
    root_session_id: rootSessionId,
  };
}

const CmuxTuiJournal = async (context) => ({
  event: async ({ event }) => {
    const nativeEvent = event && typeof event.type === "string" ? event.type : "event";
    // OpenCode also emits streaming message-part deltas. Terminal capture
    // already records their visible bytes, so reporting every token
    // would add load without adding a semantic transition.
    if (!events.has(nativeEvent)) return;
    // An interrupt (Esc) or a recoverable context overflow arrives as
    // session.error but the turn continues to idle; it is not a failure.
    const errorName = (event.properties || event.data || {}).error?.name;
    if (nativeEvent === "session.error" && NON_TERMINAL_SESSION_ERRORS.has(errorName)) return;
    const sessionTopology = topology(event);
    const handoff = appendEvent(nativeEvent, {
      event,
      context: {
        directory: context?.directory,
        worktree: context?.worktree,
        ...sessionTopology,
      },
    });
    if (nativeEvent === "session.deleted" && sessionTopology.session_id) {
      sessionRoots.delete(sessionTopology.session_id);
    }
    return handoff;
  },
});

export { CmuxTuiJournal };
export default CmuxTuiJournal;
