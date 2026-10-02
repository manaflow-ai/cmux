// The only import from the current pane (agent-session/acpmux): the acpmux transport, its
// in-page mock daemon and the row types it folds the event stream into. The view model is
// acpmux's (OWNERSHIP-PRINCIPLES.md: the pane is a projection); sharing the client keeps
// both prototypes on one projection, so they differ only in UI. Everything this pane draws
// lives under agent-session-port.
export { AcpmuxDirectClient, type AcpmuxHostConfig } from "../../agent-session/acpmux/direct";
export { MockAcpmuxSocket, mockHost, type MockScript } from "../../agent-session/acpmux/mock";
export type {
  AcpmuxActivity,
  AcpmuxFileDiff,
  AcpmuxPermission,
  AcpmuxRow,
  AcpmuxSnapshot,
} from "../../agent-session/acpmux/model";
export type { AcpmuxSessionEntry, SessionGroup } from "../../agent-session/acpmux/sessionList";
export { applyAgentTheme } from "../../agent-session/shared/theme";
export { groupByProject, projectLabel, sessionTitle } from "../../agent-session/acpmux/sessionList";
export { paneContext } from "../../agent-session/acpmux/paneContext";
