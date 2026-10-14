// A participant's initials on a neutral tile (the theme's foreground at low strength; no hue).
// Agents get a rounded square, people a circle, so a glance tells them apart.
import type { CSSProperties } from "react";
import type { HomeParticipant } from "./types";

export function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const graphemes = (word: string) => Array.from(new Intl.Segmenter().segment(word), (part) => part.segment);
  const letters =
    words.length > 1 ? [graphemes(words[0]!)[0], graphemes(words[1]!)[0]] : graphemes(words[0] ?? "?").slice(0, 2);
  return letters.join("").toUpperCase();
}

export function Avatar({ participant, size = 32 }: { participant?: HomeParticipant; size?: number }) {
  const agent = participant?.kind === "agent";
  return (
    <span
      className={`hc-avatar${agent ? " agent" : ""}${participant?.chief ? " chief" : ""}`}
      style={{ width: size, height: size, "--face": `${size}px` } as CSSProperties}
      aria-hidden="true"
    >
      {/* A small face has room for one letter only. */}
      {initials(participant?.name ?? "?").slice(0, size >= 30 ? 2 : 1)}
    </span>
  );
}
