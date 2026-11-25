// One sender icon for every place a session or agent is named: a received message's line, the
// digest of waiting messages, a subagent's row in the transcript, the tray and Session Info, a
// started chat's card (Leo, 2026-11-05: "sometimes you have the cloud icon, sometimes you only have
// the robot icon. That's a bit strange, isn't it? Like, I feel like we ought to just have it be the
// model family's icon"). The big glyph is the model family's mark and a small badge on its corner is
// the session's own glyph, a diamond or a robot, in the session's stable tone (agentTones.ts), so two
// Claude sessions read as Claude and as two. senderIconLook.ts says which is big, which badge and
// which corner. The badge cuts a ring out of the big glyph under it, so it reads on any row fill.
// A session with no family mark draws its badge glyph alone, big, in its tone; one with no tone (no
// session to tell apart) or with the badge set to none draws the family's mark alone, as before.
import { useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { AgentMark, agentBrand } from "../../shared/AgentMark";
import { harnessIcon, harnessIconsSnapshot, subscribeHarnessIcons } from "../../shared/harnessIcons";
import { Icon } from "../icons/Icon";
import { TonedIcon } from "./TonedIcon";
import { useSenderIconLook, type SenderIconBadge, type SenderIconCorner, type SenderIconLook } from "./senderIconLook";
import "./SenderIcon.css";

/// The session glyph a badge kind draws big (the icon pack's): the subagent's sparkle, the robot.
const BIG_GLYPH: Record<Exclude<SenderIconBadge, "none">, string> = { diamond: "task.ai", robot: "agent.bot" };

/// The badge's own art, filled shapes drawn for 6 to 9 px, where the pack's strokes blur: the
/// pack's four-point sparkle, and a robot's head with its eyes cut out and its antenna.
const BADGE_ART: Record<Exclude<SenderIconBadge, "none">, ReactNode> = {
  diamond: (
    <path d="M8 0.01C8.627 4.71 11.29 7.373 15.99 8C11.29 8.627 8.627 11.29 8 15.99C7.373 11.29 4.71 8.627 0.01 8C4.71 7.373 7.373 4.71 8 0.01Z" />
  ),
  robot: (
    <>
      <path
        fillRule="evenodd"
        d="M5 5.5h6a3 3 0 0 1 3 3v3a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3v-3a3 3 0 0 1 3-3ZM5.6 8.7a1.4 1.4 0 1 0 0 2.8a1.4 1.4 0 1 0 0-2.8ZM10.4 8.7a1.4 1.4 0 1 0 0 2.8a1.4 1.4 0 1 0 0-2.8Z"
      />
      <path d="M7.2 3h1.6v2.5H7.2ZM8 0.4a1.5 1.5 0 1 1 0 3a1.5 1.5 0 1 1 0-3Z" />
    </>
  ),
};

/// The badge's side for a slot of `size` px, and how far it hangs past the slot's corner.
export function badgeGeometry(size: number): { badge: number; overhang: number } {
  const badge = Math.max(6, Math.round(size * 0.58));
  return { badge, overhang: Math.round(badge * 0.25) };
}

/// The mask that cuts the big glyph under the badge, a ring 1 px wider than the badge.
export function badgeCut(size: number, corner: SenderIconCorner): string {
  const { badge, overhang } = badgeGeometry(size);
  const right = corner.endsWith("right");
  const bottom = corner.startsWith("bottom");
  const cx = right ? size + overhang - badge / 2 : badge / 2 - overhang;
  const cy = bottom ? size + overhang - badge / 2 : badge / 2 - overhang;
  const r = badge / 2 + 1;
  // l10n-allow: a CSS mask value, never shown as text.
  return `radial-gradient(circle at ${cx}px ${cy}px, transparent ${r}px, #000 ${r + 0.5}px)`;
}

function Toned({ tone, children }: { tone?: number; children: ReactNode }) {
  return (
    <span className="cv-sender-icon__toned" data-agent-tone={tone}>
      {children}
    </span>
  );
}

/// Whether `agent` draws a mark AgentMark can show: a known agent, or a harness icon other than a
/// bare glyph (AgentMark draws nothing for a glyph with no brand behind it, review F3).
function drawsMark(agent: string | undefined): boolean {
  if (agentBrand(agent)) return true;
  const icon = harnessIcon(agent);
  return !!icon && icon.kind !== "glyph";
}

export function SenderIcon({
  harness,
  tone,
  size = 14,
  fallback = "agent.session",
  fallbackNode,
  look: given,
  glyphSize = size,
  row = true,
  className,
  style,
}: {
  /// The harness the session runs (its id: a profile's own icon wins), else its family's mark.
  harness?: string;
  /// The session's stable tone (agentTones.ts `agentTone`); none draws no badge.
  tone?: number;
  /// The slot's side in px: the big glyph fills it, the badge hangs a little past its corner.
  size?: number;
  /// With no badge and no mark: the site's own glyph (an icon name, or a node).
  fallback?: string;
  fallbackNode?: ReactNode;
  /// A gallery's own look; the setting's otherwise.
  look?: SenderIconLook;
  /// A stroke glyph's own size where the site sizes logos and stroke glyphs apart (a received line's
  /// 12 px logo matches a 16 px stroke glyph's ink, IncomingMessageCard.tsx `SENDER_LOGO_SIZE`).
  glyphSize?: number;
  /// The site's glyph sits on a label line (Icon's `row`); off for a free-standing avatar.
  row?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  const setting = useSenderIconLook();
  const look = given ?? setting;
  // A profile's icon may arrive after this row mounts: whether there is a mark is asked again.
  useSyncExternalStore(subscribeHarnessIcons, harnessIconsSnapshot, harnessIconsSnapshot);
  const family = harness?.split(/[-_/]/)[0];
  const mark = drawsMark(harness) ? harness : family && drawsMark(family) ? family : undefined;
  const wrap = (node: ReactNode, badged?: boolean) => (
    <span
      className={`cv-sender-icon${className ? ` ${className}` : ""}`}
      style={{ ...style, width: size, height: size }}
      data-badged={badged || undefined}
      aria-hidden="true"
    >
      {node}
    </span>
  );
  // No badge (Sender Badge: None, or no session to tell apart): the icon as rows drew it before, the
  // family's mark, else the site's glyph in the session's tone, with no wrapper of its own.
  if (tone === undefined || look.badge === "none") {
    const glyph = fallbackNode ? (
      <Toned tone={tone}>{fallbackNode}</Toned>
    ) : (
      <TonedIcon name={fallback} size={size} tone={tone} row={row} />
    );
    return mark ? <AgentMark agent={mark} size={size} fallback={glyph} /> : glyph;
  }
  const big = (
    <Toned tone={tone}>
      <Icon name={BIG_GLYPH[look.badge]} size={glyphSize} row={row} />
    </Toned>
  );
  // No family to show: the session's glyph alone, big, in its tone.
  if (!mark) return wrap(big);
  const { badge, overhang } = badgeGeometry(size);
  const cut = badgeCut(size, look.corner);
  const small =
    look.lead === "family" ? (
      <Toned tone={tone}>
        <svg viewBox="0 0 16 16" width={badge} height={badge} fill="currentColor" focusable="false">
          {BADGE_ART[look.badge]}
        </svg>
      </Toned>
    ) : (
      <AgentMark agent={mark} size={badge} />
    );
  return wrap(
    <>
      <span className="cv-sender-icon__main" style={{ mask: cut, WebkitMask: cut }}>
        {look.lead === "family" ? <AgentMark agent={mark} size={size} /> : big}
      </span>
      <span
        className="cv-sender-icon__badge"
        data-corner={look.corner}
        data-badge={look.lead === "family" ? look.badge : "family"}
        style={{ width: badge, height: badge, ["--cv-sender-overhang" as string]: `${-overhang}px` }}
      >
        {small}
      </span>
    </>,
    true,
  );
}
