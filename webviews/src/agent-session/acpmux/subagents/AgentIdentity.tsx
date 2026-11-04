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

/// The stable hue on a subagent's harness mark. Alternatives are kept in the gallery.
export type AgentIdentityLook = "tint" | "badge" | "marker";

/// One identity mark shared by agent and session lists. A missing harness keeps the same icon slot,
/// and subagent surfaces tint every harness in the same stable identity tone.
export function AgentIdentity({
  harness,
  tone,
  size = 14,
  fallback = "agent.session",
  fallbackNode,
  className,
  style,
  look,
}: {
  harness?: string;
  tone?: number;
  size?: number;
  fallback?: string;
  fallbackNode?: ReactNode;
  className?: string;
  style?: CSSProperties;
  look?: AgentIdentityLook;
}) {
  // Keep the full id subscribed: a profile icon may arrive after this row mounts.
  const family = harness?.split(/[-_/]/)[0];
  const glyph = (
    <span data-agent-tone={tone} style={{ color: "var(--agent-tone-ink, var(--agent-muted))" }}>
      {fallbackNode ?? <Icon name={fallback} size={size} row />}
    </span>
  );
  return (
    <span
      className={[className, look && "acpmux-agent-identity"].filter(Boolean).join(" ") || undefined}
      style={style}
      data-agent-tone={look ? tone : undefined}
      data-identity-look={look}
      aria-hidden="true"
    >
      <AgentMark
        agent={harness}
        size={size}
        tint={look === "tint"}
        fallback={
          family && family !== harness ? (
            <AgentMark agent={family} size={size} tint={look === "tint"} fallback={glyph} />
          ) : (
            glyph
          )
        }
      />
    </span>
  );
}
