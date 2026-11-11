// l10n-allow-file: gallery fixtures, not shipped UI.
import { ROW_ICON } from "../conversation/messageActionsModel";
import { FORK_ICON } from "./forkIcon";
import { Icon } from "./Icon";

/**
 * The fork glyph candidates in the message action row, between the neighbours it sits with (Copy,
 * Pin, Read aloud, More), light and dark, at the row's size, at 12 and at 20 (Leo 2026-11-09: "and this
 * fork symbol is so bad"). The chosen drawing is the pack's `agent.fork`; the others are frozen here as
 * paths on the pack's 24 grid at its 1.5 stroke.
 */
export type ForkGlyphCandidate = "fork-mark" | "soft-fork" | "turned-y" | "sideways" | "before";

export interface ForkGlyphGalleryProps {
  fork: ForkGlyphCandidate;
}

const NODE = (cx: number, cy: number) => `M${cx - 2.25} ${cy}a2.25 2.25 0 1 0 4.5 0a2.25 2.25 0 1 0 -4.5 0`;

const PATHS: Record<Exclude<ForkGlyphCandidate, "fork-mark">, string[]> = {
  "soft-fork": [NODE(7, 6), NODE(17, 6), NODE(12, 18), "M7 8.25c0 3.75 5 3 5 7.5M17 8.25c0 3.75-5 3-5 7.5"],
  "turned-y": ["M3.5 12h5c3 0 3.5-5.5 7-5.5h5M8.5 12c3 0 3.5 5.5 7 5.5h5", "M17.5 3.5l3 3-3 3M17.5 14.5l3 3-3 3"],
  sideways: [
    NODE(6, 12),
    NODE(18, 7),
    NODE(18, 17),
    "M15.75 7h-1.25c-1.4 0-2.5 1.1-2.5 2.5v5c0 1.4 1.1 2.5 2.5 2.5h1.25M12 12H8.25",
  ],
  before: ["M3.5 15.5H20M8.5 15.5c2.8 0 4.2-1.4 5.8-3.5L19.5 5", "M17 12.5l3 3-3 3M15 5h4.5v4.5"],
};

function Fork({ fork, size }: { fork: ForkGlyphCandidate; size: number }) {
  if (fork === "fork-mark") return <Icon name={FORK_ICON} size={size} />;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {PATHS[fork].map((d) => (
        <path key={d} d={d} />
      ))}
    </svg>
  );
}

/** Light and dark side by side, in the system's own canvas colours for each scheme. */
const SCHEMES = ["light", "dark"] as const;
const LARGE = 20;

function Row({ fork, size }: { fork: ForkGlyphCandidate; size: number }) {
  const slot = {
    display: "inline-flex",
    width: size + 12,
    height: size + 12,
    alignItems: "center",
    justifyContent: "center",
  };
  return (
    <div role="toolbar" aria-label="Message actions" style={{ display: "flex", alignItems: "center", gap: 4 }}>
      <span style={slot}>
        <Icon name="action.copy" size={size} />
      </span>
      <span style={{ ...slot, borderRadius: 6, background: "color-mix(in srgb, currentColor 10%, transparent)" }}>
        <Fork fork={fork} size={size} />
      </span>
      <span style={slot}>
        <Icon name="action.pin" size={size} />
      </span>
      <span style={slot}>
        <Icon name="media.audio" size={size} />
      </span>
      <span style={slot}>
        <Icon name="action.more" size={size} />
      </span>
    </div>
  );
}

export function ForkGlyphGallery({ fork }: ForkGlyphGalleryProps) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr" }}>
      {SCHEMES.map((scheme) => (
        <section
          key={scheme}
          data-scheme={scheme}
          style={{
            colorScheme: scheme,
            background: "Canvas",
            color: "CanvasText",
            padding: 16,
            display: "grid",
            gap: 12,
          }}
        >
          <Row fork={fork} size={ROW_ICON} />
          <Row fork={fork} size={12} />
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <Fork fork={fork} size={LARGE} />
            <span style={{ color: "GrayText", fontSize: "var(--text-caption)" }}>Fork from here</span>
          </div>
        </section>
      ))}
    </div>
  );
}
