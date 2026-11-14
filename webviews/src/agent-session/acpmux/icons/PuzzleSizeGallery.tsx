// l10n-allow-file: gallery fixtures, not shipped UI.
import type { CSSProperties } from "react";
import { Icon } from "./Icon";

/**
 * The pack's puzzle beside the glyphs it sits next to in the palette and the sidebar's app sections
 * (Leo, 2026-11-07: "Why is the puzzle icon so ... big?"). The shipped puzzle takes SPEC's 10% coverage
 * trim; the other candidates scale it back up to the 6% trim and to the untrimmed drawing (a CSS scale,
 * so their strokes thicken a little with it).
 */
export interface PuzzleSizeGalleryProps {
  /** The puzzle's scale against the shipped drawing: 1 is the 10% trim. */
  scale: number;
}

const SIZES = [12, 14, 16, 20] as const;
const NEIGHBOURS = ["search", "home", "folder", "extension", "settings"] as const;

export function PuzzleSizeGallery({ scale }: PuzzleSizeGalleryProps) {
  const puzzle: CSSProperties = { transform: `scale(${scale})` };
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: `auto repeat(${NEIGHBOURS.length}, 28px)`,
        alignItems: "center",
        justifyItems: "center",
        gap: 12,
        padding: 24,
        fontSize: "var(--text-caption)",
        color: "var(--cmux-text-primary, #e4e4e7)",
      }}
    >
      <span />
      {NEIGHBOURS.map((name) => (
        <span key={name} style={{ opacity: 0.6 }}>
          {name === "extension" ? "puzzle" : name}
        </span>
      ))}
      {SIZES.map((size) => [
        <span key={`label-${size}`} style={{ justifySelf: "start" }}>
          {size} pt
        </span>,
        ...NEIGHBOURS.map((name) => (
          <span key={`${name}-${size}`}>
            <Icon name={name} size={size} style={name === "extension" ? puzzle : undefined} />
          </span>
        )),
      ])}
    </div>
  );
}
