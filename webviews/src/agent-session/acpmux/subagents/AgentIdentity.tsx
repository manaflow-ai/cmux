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
  plain = false,
  blankUnknown = false,
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
  /// The mark alone whatever the Sender Badge setting: no session badge over it (the composer hat;
  /// Leo 2026-11-23 on the hat's rows, a colored badge on every Claude mark: "weird and bad and unncessary"). The tone still colors a fallback glyph.
  plain?: boolean;
  /// No glyph at all while the harness is unknown (the composer hat, before a chat's harness has
  /// come): its slot stays, empty, rather than a generic sparkle that names nothing (Leo, 2026-11-27:
  /// "there was a really dumb looking symbol in the top left of the composer hat when i loaded into
  /// this chat").
  blankUnknown?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  const look = useSenderIconLook();
  if (blankUnknown && !harness)
    return (
      <span
        className={className}
        style={{ display: "inline-block", width: size, height: size, flex: "none", ...style }}
        data-agent-mark="unknown"
        aria-hidden="true"
      />
    );
  if (!plain && look.badge !== "none" && tone !== undefined)
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
