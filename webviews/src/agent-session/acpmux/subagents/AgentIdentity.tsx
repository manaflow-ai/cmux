import type { ReactNode } from "react";
import { AgentMark, knownMark } from "../../shared/AgentMark";
import { Icon } from "../icons/Icon";

/// The type label is already established by a list heading or a harness mark. Keep it out of
/// every row so the mark carries the identity instead of repeating "Subagent".
export function isRepeatedAgentKind(kind: string | undefined): boolean {
  return !!kind && /^(?:sub[ -]?agent|sub[ -]?session|agent)$/iu.test(kind.trim());
}

/// One identity mark shared by agent and session lists. A missing harness keeps the same icon slot,
/// but the stable tone makes two unknown harnesses distinguishable.
export function AgentIdentity({
  harness,
  tone,
  size = 14,
  fallback = "agent.session",
  fallbackNode,
  className,
}: {
  harness?: string;
  tone?: number;
  size?: number;
  fallback?: string;
  fallbackNode?: ReactNode;
  className?: string;
}) {
  const mark = harness ? knownMark(harness, harness.split(/[-_/]/)[0]) : undefined;
  return (
    <span
      className={className}
      data-agent-tone={tone}
      style={{ color: "var(--agent-tone-ink, var(--agent-muted))" }}
      aria-hidden="true"
    >
      <AgentMark
        agent={mark}
        size={size}
        fallback={fallbackNode ?? <Icon name={fallback} size={size} row />}
      />
    </span>
  );
}
