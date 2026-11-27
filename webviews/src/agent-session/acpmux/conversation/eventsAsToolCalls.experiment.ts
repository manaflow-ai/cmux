// The switch in Settings > Advanced > Experiments (`experiments.eventsAsToolCalls`, off by default)
// for the cmuxterm-hq design "Events that are tool calls" (docs/design/events-that-are-tool-calls.md):
// harness events that are not quite a tool call and not quite the person's message are classified
// by their origin field, never by their text. experiments/switches.ts carries it to the page.
//
// What it changes today (the design's plan item "Add `subagent_resume` and `announcement` to the
// known kinds"): both provenance kinds acpmux sends (hub/subagent_resume.rs, hub/forum.rs
// `PROVENANCE_KIND`) are known to incomingMessage.ts, and an urgent forum rule acpmux pushes into a
// chat (`announcement`, no sender of its own) draws as acpmux's line, as the turn cap and the inbox
// digest do, instead of falling through to the person's prompt. Off keeps today's reading.
import { experimentSwitchOn } from "../../../experiments/switches";

export const EVENTS_AS_TOOL_CALLS_SWITCH = "eventsAsToolCalls";

/// Whether the person turned the switch on (read at classify time; a flip applies to rows read after it).
export function eventsAsToolCallsOn(): boolean {
  return experimentSwitchOn(EVENTS_AS_TOOL_CALLS_SWITCH);
}
