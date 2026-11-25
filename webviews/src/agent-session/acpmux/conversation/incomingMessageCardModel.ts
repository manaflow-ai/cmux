import { knownMark } from "../../shared/AgentMark";
import { harnessLabel, runModel } from "../subagents/agentRuns";

/// The harness whose mark a sender draws: the listed chat's, else the one the message names (acpmux's
/// bound `fromHarness`), the first of them with a mark today, else that harness id itself, so a
/// profile icon that arrives later still replaces the fallback. Never one guessed from the sender's
/// name: a Codex lane called `claude-…` drew Claude's mark (cmux#30247). With neither, undefined,
/// and the line draws the neutral agent glyph.
export function senderHarness(listed: string | undefined, named: string | undefined): string | undefined {
  return knownMark(listed, named, listed ?? named);
}

/// What a sender runs on, for its line's hover: "Codex · gpt-6.1-sol high", its harness's name, then
/// its model and effort (a listed chat's, else the ones the message names), each only when known
/// (Leo, 2026-10-28: "when you hover over the button, it should be able to tell you, like, a bit
/// more metadata. Like, at the very least tell you what model did it, what effort level").
export function senderAbout(
  harness: string | undefined,
  listed: { model?: string; effort?: string } | undefined,
  named: { model?: string; effort?: string },
): string | undefined {
  const model = runModel({ model: listed?.model ?? named.model, effort: listed?.effort ?? named.effort });
  return [harness && harnessLabel(harness), model].filter(Boolean).join(" · ") || undefined;
}

/// A sender's name as its line shows it beside its machine: a peer's chat comes named
/// `<machine>/<name>` (acpmux hub/peers.rs), and the line names the machine after the name already,
/// so the name drops that prefix: "merge-timeout · lane-vm-01", never "lane-vm-01/merge-timeout ·
/// lane-vm-01" (Leo, 2026-11-02, on that line: "wtf these tool call spacing things are still weird").
export function senderLabel(name: string, host: string | undefined): string {
  const prefix = host ? `${host}/` : "";
  return prefix && name.toLowerCase().startsWith(prefix.toLowerCase()) && name.length > prefix.length
    ? name.slice(prefix.length)
    : name;
}
