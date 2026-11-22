// What the prompt rail shows and its head control: the two settings, read by chatDisplay.ts and the
// rail (model.ts `railEntries`, ThreadMinimap.tsx). No imports, so both can read it.

/// What the rail shows (Settings > Agent Chat > Prompt Rail Shows, `agentPane.display.rail.show`), picked
/// from its right-click menu or its head control (Leo, 2026-11-21: "left side scroll prompt rail shows your
/// prompts. why cant you see an agents'? why cant you filter it? customize it immediately?"). One list at a
/// time, every tick drawn alike, so the rail keeps its one column (threadMinimap.css): `prompts` is the rail
/// as it was (every prompt); `mine` and `received` split it by sender; `replies` is a tick per agent reply;
/// `everything` puts each reply after its prompt; the rest keep the turns that used tools, edited files,
/// failed or started subagents, each at its reply.
export const RAIL_SHOWS = [
  "prompts",
  "mine",
  "received",
  "replies",
  "everything",
  "errors",
  "edits",
  "tools",
  "subagents",
] as const;
export type RailShow = (typeof RAIL_SHOWS)[number];
export const DEFAULT_RAIL_SHOW: RailShow = "prompts";
export const isRailShow = (value: unknown): value is RailShow => RAIL_SHOWS.includes(value as RailShow);

export const RAIL_SHOW_KEY = "agentPane.display.rail.show";

/// Settings > Agent Chat > Prompt Rail Button, off by default: a small control at the rail's head, drawn
/// only while the pointer is on the rail (or a filter is on), that names what the rail shows and opens
/// the same choices as its right-click menu.
export const RAIL_CONTROL_KEY = "agentPane.display.rail.control";
