// cmux-tui-journal-plugin
import { spawn } from "node:child_process";

const helper = process.env.CMUX_TUI_HOOK;
const events = new Set([
  "session.created",
  "session.updated",
  "session.status",
  "session.idle",
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
const sessionRoots = new Map();

function topology(event) {
  const properties = event?.properties || {};
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

function emit(nativeEvent, native) {
  if (!process.env.CMUX_TUI_SOCKET || !process.env.CMUX_TUI_TERMINAL_ID || !helper) return;
  let payload;
  try {
    payload = JSON.stringify(native);
  } catch (_) {
    return;
  }
  const child = spawn(helper, ["opencode", nativeEvent], {
    env: process.env,
    stdio: ["pipe", "ignore", "ignore"],
  });
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.stdin.end(payload);
}

const CmuxTuiJournal = async (context) => ({
  event: async ({ event }) => {
    const nativeEvent = event && typeof event.type === "string" ? event.type : "event";
    // OpenCode also emits streaming message-part deltas. Terminal capture
    // already records their visible bytes, so spawning one process per token
    // would add load without adding a semantic transition.
    if (!events.has(nativeEvent)) return;
    const sessionTopology = topology(event);
    emit(nativeEvent, {
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
  },
});

export { CmuxTuiJournal };
export default CmuxTuiJournal;
