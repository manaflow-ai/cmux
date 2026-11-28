import type { StringKey } from "../i18n";
import type { RailShow } from "./railShow";

/// The rail menu's show items (railShow.ts `RailShow`).
export const RAIL_SHOW_LABEL = {
  prompts: "minimap.filterAll",
  mine: "minimap.filterMine",
  received: "minimap.filterAgents",
  replies: "minimap.showReplies",
  everything: "minimap.showEverything",
  errors: "minimap.showErrors",
  edits: "minimap.showEdits",
  tools: "minimap.showTools",
  subagents: "minimap.showSubagents",
} as const satisfies Record<RailShow, StringKey>;
