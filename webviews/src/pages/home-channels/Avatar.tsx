// A participant's initials on a neutral tile (the theme's foreground at low strength; no hue).
// Agents get a rounded square, people a circle, so a glance tells them apart. A Chief's tile can
// carry its live state as a small mark on the corner (working: a quiet pulse; waiting: the one
// warning color). A channel is a hash tile with a hairline.
import type { ChiefState } from "./model";
import type { HomeParticipant } from "./types";

export function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const graphemes = (word: string) => Array.from(new Intl.Segmenter().segment(word), (part) => part.segment);
  const letters =
    words.length > 1 ? [graphemes(words[0]!)[0], graphemes(words[1]!)[0]] : graphemes(words[0] ?? "?").slice(0, 2);
  return letters.join("").toUpperCase();
}

export function Avatar({
  participant,
  size = 20,
  state,
}: {
  participant?: HomeParticipant;
  size?: number;
  /** A Chief's live state, drawn on the tile's corner (idle draws nothing). */
  state?: ChiefState;
}) {
  const agent = participant?.kind === "agent";
  return (
    <span
      className={`hc-avatar${size >= 24 ? " large" : ""}${agent ? " agent" : ""}${participant?.chief ? " chief" : ""}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {/* A small tile has room for one letter only. */}
      {initials(participant?.name ?? "?").slice(0, size >= 24 ? 2 : 1)}
      {state && state !== "idle" && <span className={`lg-state-mark ${state}`} />}
    </span>
  );
}

export function ChannelMark({ size = 20 }: { size?: number }) {
  return (
    <span className="lg-channel-mark" style={{ width: size, height: size }} aria-hidden="true">
      #
    </span>
  );
}
