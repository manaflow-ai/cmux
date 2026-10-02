import React from "react";

/// One agent's mark: monochrome paths drawn in currentColor, so the theme's text
/// tokens tint it. `brandColor` is kept for a later brand-color mode, and
/// `source` records where the official artwork came from (see AGENT_MARKS.md).
export type AgentMarkSpec = {
  viewBox: string;
  paths: string[];
  fillRule?: "evenodd";
  brandColor?: string;
  source: string;
};

/// Marks by agent key. Only official artwork from each vendor's brand or press
/// assets goes here; an agent without one draws the generic agent glyph.
export const AGENT_MARKS: Record<string, AgentMarkSpec> = {};

/// The agent a harness id names: its first word, lowercased. acpmux names harnesses
/// by config id, so variants share their agent ("claude-sr" is "claude").
export function agentKey(id: string | undefined): string | undefined {
  const word = id?.split(/[-_\s]+/).find(Boolean);
  return word ? word.toLowerCase() : undefined;
}

/// An agent's mark, at `size` px, for the model menu, the pane header, session rows
/// and new-tab cards. With `label` it is an image named for the agent; without, it
/// is decoration beside text that already names it.
export function AgentMark({ agent, size = 16, label }: { agent?: string; size?: number; label?: string }) {
  const key = agentKey(agent);
  const spec = key ? AGENT_MARKS[key] : undefined;
  const a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": true as const };
  if (!spec)
    return (
      <svg
        className="agent-mark agent-mark-generic"
        width={size}
        height={size}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.25}
        strokeLinecap="round"
        strokeLinejoin="round"
        focusable="false"
        {...a11y}
      >
        <rect x="2.25" y="2.75" width="11.5" height="10.5" rx="2.5" />
        <path d="m5.25 6.5 2 1.75-2 1.75M8.75 10h2" />
      </svg>
    );
  return (
    <svg
      className="agent-mark"
      data-agent={key}
      width={size}
      height={size}
      viewBox={spec.viewBox}
      fill="currentColor"
      focusable="false"
      {...a11y}
    >
      {spec.paths.map((d, index) => (
        <path key={index} d={d} fillRule={spec.fillRule} clipRule={spec.fillRule} />
      ))}
    </svg>
  );
}
