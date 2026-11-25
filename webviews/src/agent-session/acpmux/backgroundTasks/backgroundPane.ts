// Background tasks as a tab in the chat's right column (Leo, 2026-11-03: "it should be opening up on
// the right pane as a tab instead of this"). The app already opens a chat's subagents there
// (`chat.subagentPane`, subagents/subagentPanes.ts, AgentSubagentPanes.swift): a tab on the chat's own
// session, placed where RightColumnPlacement puts anything opened right of the chat, one per chat
// (a second open focuses it), named after the title the page sends, and opened on a `subagent:<id>`
// reveal. This panel rides the same path under a reserved id no subagent has, so the native side
// needs nothing new: the tab's page reads the reveal and shows the panel alone, filling the tab.
// A host that opens no pane (the gallery, the floating chat, an older app) keeps the panel in the
// chat's own column, as before.
import { openSubagentPane } from "../subagents/subagentPanes";

/// The reserved pane id. acpmux subagent ids are tool call ids and uuids, never with a colon.
export const BACKGROUND_PANE = "cmux:background-tasks";

/// Whether a `subagent:` reveal's id names this panel's tab rather than a subagent.
export const isBackgroundPane = (id: string | undefined) => id === BACKGROUND_PANE;

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app to open (or focus) the chat's Background tasks tab on its right, its tab named
/// `title`; false when the host opened none.
export const openBackgroundPane = (call: Call, title: string) => openSubagentPane(call, BACKGROUND_PANE, true, title);
