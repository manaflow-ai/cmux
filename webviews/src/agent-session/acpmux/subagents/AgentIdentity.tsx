import type { CSSProperties, ReactNode } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { Icon } from "../icons/Icon";
import { SenderIcon } from "./SenderIcon";
import { useSenderIconLook } from "./senderIconLook";

/// One identity mark shared by agent and session lists: the sender icon (SenderIcon.tsx), the
/// family's mark with the session's badge in its stable tone. With the badge off (Sender Badge:
/// None) it is the mark as before: the harness's, else its family's, else the fallback glyph in its
/// tone. A missing harness keeps the same icon slot, and the tone tells two unknown harnesses apart.
export function AgentIdentity({
  harness,
  tone,
  size = 14,
  fallback = "agent.session",
  fallbackNode,
  glyphSize,
  className,
  style,
}: {
  harness?: string;
  tone?: number;
  size?: number;
  fallback?: string;
  fallbackNode?: ReactNode;
  /// A badged sender's stroke glyph size (SenderIcon.tsx `glyphSize`).
  glyphSize?: number;
  className?: string;
  style?: CSSProperties;
}) {
  const look = useSenderIconLook();
  if (look.badge !== "none" && tone !== undefined)
    return (
      <SenderIcon
        harness={harness}
        tone={tone}
        size={size}
        fallback={fallback}
        fallbackNode={fallbackNode}
        glyphSize={glyphSize}
        className={className}
        style={style}
      />
    );
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
