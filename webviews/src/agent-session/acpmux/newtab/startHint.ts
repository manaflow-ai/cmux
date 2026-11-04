// A new chat's start, drawn on the New Tab page's first frame (Leo, 2026-11-03: "the read defaults/
// the "not working in a project" thing that should all be instant"). The host's context carries
// where the chat starts as the app already knows it (AgentPaneNewTabStart: the seed or New Tab
// folder, the pane's chosen folder, the workspace's roots, else none with Choose Folder…), so the
// page names the project, or Do not work in a project, before acpmux answers the handshake. The
// handshake's answer from the store reconciles it: the same answer changes nothing.
import type { NewTabStart } from "../NewTabPage";

/// The pane's start state: a new chat, its project folder (none: agent-home), Choose Folder… offered.
export type StartState = { newSession: boolean; projectDraft?: string; chooseFolder: boolean };

/// The start a context's `start` draws; undefined without one (an older host, a chat): the
/// handshake decides, as before.
export function startFromContext(start: NewTabStart | undefined): StartState | undefined {
  if (!start) return undefined;
  return { newSession: true, ...(start.cwd ? { projectDraft: start.cwd } : {}), chooseFolder: start.chooseFolder };
}

/// The project folder after the handshake's start folder (`answered`) for a new chat: the store's
/// folder when it names one; when it names none (agent-home), the context's folder (`hinted`) goes
/// unless the person picked another meanwhile (`current` differs), which stays.
export function reconciledProject(
  current: string | undefined,
  hinted: string | undefined,
  answered: string | undefined,
): string | undefined {
  if (answered) return answered;
  return hinted !== undefined && current === hinted ? undefined : current;
}
