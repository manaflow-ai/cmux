import type { CSSProperties, ReactNode } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { Icon } from "../icons/Icon";

/// The type label is already established by a list heading or a harness mark. Keep it out of
/// every row so the mark carries the identity instead of repeating "Subagent".
export function isRepeatedAgentKind(kind: string | undefined): boolean {
  return !!kind && /^(?:sub[ -]?agent|sub[ -]?session|agent)$/iu.test(kind.trim());
}

/// A subagent's own mark when no harness is known: never the chat bubble (`agent.session`) its
/// parent chat and every session list draw (Leo, 2026-10-28: "Shouldn't the subagent icon be
/// different?").
export const SUBAGENT_FALLBACK = "task.ai";

/// One identity mark shared by agent and session lists. A missing harness keeps the same icon slot,
/// but the stable tone makes two unknown harnesses distinguishable.
export function AgentIdentity({
  harness,
  tone,
  size = 14,
  fallback = "agent.session",
  fallbackNode,
  className,
  style,
}: {
  harness?: string;
  tone?: number;
  size?: number;
  fallback?: string;
  fallbackNode?: ReactNode;
  className?: string;
  style?: CSSProperties;
}) {
  // Keep the full id subscribed: a profile icon may arrive after this row mounts.
  const family = harness?.split(/[-_/]/)[0];
  const glyph = (
    <span data-agent-tone={tone} style={{ color: "var(--agent-tone-ink, var(--agent-muted))" }}>
      {fallbackNode ?? <Icon name={fallback} size={size} row />}
    </span>
  );
  return (
    <span className={className} style={style} aria-hidden="true">
      <AgentMark
        agent={harness}
        size={size}
        fallback={family && family !== harness ? <AgentMark agent={family} size={size} fallback={glyph} /> : glyph}
      />
    </span>
  );
}
