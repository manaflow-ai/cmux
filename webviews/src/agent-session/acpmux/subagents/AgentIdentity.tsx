import { useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { AgentMark } from "../../shared/AgentMark";
import { harnessIconsSnapshot, subscribeHarnessIcons } from "../../shared/harnessIcons";
import { Icon } from "../icons/Icon";
import { harnessFamily } from "./agentRuns";

/// The type label is already established by a list heading or a harness mark. Keep it out of
/// every row so the mark carries the identity instead of repeating "Subagent".
export function isRepeatedAgentKind(kind: string | undefined): boolean {
  return !!kind && /^(?:sub[ -]?agent|sub[ -]?session|agent)$/iu.test(kind.trim());
}

/// A subagent's own mark when no harness is known: never the chat bubble (`agent.session`) its
/// parent chat and every session list draw (Leo, 2026-10-28: "Shouldn't the subagent icon be
/// different?").
export const SUBAGENT_FALLBACK = "task.ai";

/// The harness mark a subagent's row draws: only one of another model family than its chat's (a
/// Codex subagent under Claude). One of the chat's own family draws the subagent mark in its own
/// tone instead, so a list of them tells apart, never the same Claude mark on every line (Leo,
/// 2026-11-04: "didn't we see better stacked subagents or whatever earlier idk these all being
/// claude"; 2026-10-29: "one of these is Codex, one of these is Claude").
export function foreignHarness(harness: string | undefined, chatHarness: string | undefined): string | undefined {
  if (!harness) return undefined;
  return chatHarness && harnessFamily(harness) === harnessFamily(chatHarness) ? undefined : harness;
}

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
  const icons = useSyncExternalStore(subscribeHarnessIcons, harnessIconsSnapshot, harnessIconsSnapshot);
  const own = (harness && icons.get(harness)) || (family && icons.get(family));
  // A photo's alpha mask can be a solid square, and emoji have their own colours. Preserve the
  // person's chosen artwork; the same small hue badge carries identity without changing its box.
  const preserve = own && (own.kind === "image" || own.kind === "emoji" || own.kind === "monogram");
  const shown = look === "tint" && tone !== undefined && preserve ? "badge" : look;
  const glyph = (
    <span data-agent-tone={tone} style={{ color: "var(--agent-tone-ink, var(--agent-muted))" }}>
      {fallbackNode ?? <Icon name={fallback} size={size} row />}
    </span>
  );
  return (
    <span
      className={[className, shown && "acpmux-agent-identity"].filter(Boolean).join(" ") || undefined}
      style={style}
      data-agent-tone={shown ? tone : undefined}
      data-identity-look={shown}
      aria-hidden="true"
    >
      <AgentMark
        agent={harness}
        size={size}
        tint={shown === "tint"}
        fallback={
          family && family !== harness ? (
            <AgentMark agent={family} size={size} tint={shown === "tint"} fallback={glyph} />
          ) : (
            glyph
          )
        }
      />
    </span>
  );
}
