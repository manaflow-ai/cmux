import type { Plugin } from "vite";

// A started local session may omit cwd. Change only the mock daemon's row so the pane
// handles the same summary it receives in production, including its normal startup.
export const attachmentWithoutCwd: Plugin = {
  name: "attachment-without-cwd",
  transform(code, id) {
    if (!id.endsWith("/acpmux/mockFixture.ts")) return;
    return (
      code +
      '\nif (new URLSearchParams(location.search).has("noCwd")) delete mockSessions.find(s => s.sessionId === WORKED_SESSION).cwd;'
    );
  },
};
