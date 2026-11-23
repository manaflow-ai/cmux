// l10n-allow-file: gallery-only fixture names and comparison labels; not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import { AgentIdentityChip, type FkaTreatment } from "./AgentIdentityChip";

// A small SVG face, as `acpmux icon @ ./mango.svg` sends it (base64, no file or network access).
const MANGO_SVG =
  "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxNiAxNiI+PGNpcmNsZSBjeD0iOCIgY3k9IjgiIHI9IjciIGZpbGw9IiNmNWE2MjMiLz48cGF0aCBkPSJNNSA5YzEgMiA1IDIgNiAwIiBzdHJva2U9IiM3YTNlMDAiIHN0cm9rZS13aWR0aD0iMS40IiBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSI2IiBjeT0iNi41IiByPSIxIiBmaWxsPSIjN2EzZTAwIi8+PGNpcmNsZSBjeD0iMTAiIGN5PSI2LjUiIHI9IjEiIGZpbGw9IiM3YTNlMDAiLz48L3N2Zz4=";

type Sample = {
  state: string;
  name: string;
  icon?: HarnessIconSpec;
  harness?: string;
  formerNames?: string[];
};

const SAMPLES: readonly Sample[] = [
  {
    state: "Emoji",
    name: "Mango",
    icon: { kind: "emoji", text: "🥭", source: "session" },
    harness: "claude",
    formerNames: ["claude-sr2-7", "claude-sr2-coord-old"],
  },
  {
    // The gallery has no host to draw SF Symbols, so the symbol's monogram shows, as on a page
    // whose host cannot draw it.
    state: "SF Symbol (monogram fallback)",
    name: "Kiwi",
    icon: { kind: "symbol", name: "leaf.fill", text: "K", hue: 142, source: "session" },
    harness: "codex",
    formerNames: ["codex-lane-10"],
  },
  {
    state: "Image (SVG)",
    name: "Papaya",
    icon: { kind: "image", mime: "image/svg+xml", data: MANGO_SVG, source: "session" },
    harness: "claude",
    formerNames: ["review-bot"],
  },
  { state: "No icon (harness mark)", name: "Guava", harness: "claude", formerNames: ["claude-3"] },
  { state: "Never renamed", name: "Lychee", icon: { kind: "emoji", text: "🍒", source: "session" }, harness: "codex" },
  {
    state: "Long names",
    name: "Coordinator for the reconnect regression across the build fleet",
    icon: { kind: "brand", brand: "gemini", source: "session" },
    harness: "gemini",
    formerNames: ["gcp-gemini-lane-14-coordinator-previous-handle"],
  },
];

const TREATMENTS: readonly { fka: FkaTreatment; label: string }[] = [
  { fka: "tooltip", label: "(a) fka in the tooltip only" },
  { fka: "inline", label: "(b) inline muted fka (default)" },
  { fka: "stacked", label: "(c) fka stacked under the name" },
];

/** The look before given names reached the app: the chat's old name and its harness mark only. */
function Before() {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8, minWidth: 0, flex: "1 1 0" }}>
      {SAMPLES.map((sample) => (
        <div key={sample.state} style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
          <span style={{ color: "var(--agent-soft)", fontSize: "var(--text-caption)" }}>{sample.state}</span>
          <span style={{ display: "flex", minWidth: 0, color: "var(--agent-text)", fontSize: "var(--text-control)" }}>
            <AgentIdentityChip
              name={sample.formerNames?.at(-1) ?? sample.name}
              fka="tooltip"
              {...(sample.harness && { harness: sample.harness })}
            />
          </span>
        </div>
      ))}
    </div>
  );
}

function Column({ fka, label }: { fka: FkaTreatment; label?: string }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8, minWidth: 0, flex: "1 1 0" }}>
      {label && <div style={{ color: "var(--agent-muted)", fontSize: "var(--text-caption)" }}>{label}</div>}
      {SAMPLES.map((sample) => (
        <div key={sample.state} style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
          <span style={{ color: "var(--agent-soft)", fontSize: "var(--text-caption)" }}>{sample.state}</span>
          <span
            style={{
              display: "flex",
              minWidth: 0,
              maxWidth: "100%",
              color: "var(--agent-text)",
              fontSize: "var(--text-control)",
            }}
          >
            <AgentIdentityChip
              name={sample.name}
              fka={fka}
              {...(sample.icon && { icon: sample.icon })}
              {...(sample.harness && { harness: sample.harness })}
              {...(sample.formerNames && { formerNames: sample.formerNames })}
            />
          </span>
        </div>
      ))}
    </div>
  );
}

function AgentIdentityGallery({ fka }: { fka: FkaTreatment | "compare" | "before" }) {
  if (fka === "before") {
    return (
      <div className="acpmux-shell" style={{ padding: 16, background: "var(--agent-page-bg)" }}>
        <Before />
      </div>
    );
  }
  return (
    <div className="acpmux-shell" style={{ padding: 16, background: "var(--agent-page-bg)" }}>
      <div style={{ display: "flex", gap: 24, alignItems: "flex-start" }}>
        {fka === "compare" ? (
          TREATMENTS.map((treatment) => <Column key={treatment.fka} {...treatment} />)
        ) : (
          <Column fka={fka} />
        )}
      </div>
    </div>
  );
}

export default componentEntry<{ fka: FkaTreatment | "compare" | "before" }>({
  id: "agent-pane.agent-identity",
  title: "Agent name, icon and fka",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 360, normal: 720, wide: 1040 },
  keywords: ["display name", "fka", "formerly", "alias", "rename", "session icon", "emoji", "favicon"],
  covers: [
    "agent-session/acpmux/AgentIdentityChip.tsx#AgentIdentityChip",
    "agent-session/shared/AgentMark.tsx#SessionMark",
  ],
  styles: () => import("./styles.css"),
  load: async () => AgentIdentityGallery,
  variants: {
    before: {
      props: { fka: "before" },
      note: "Before: a chat showed only its old session name and its harness mark; the name and icon it was given reached no tab, list or header.",
    },
    compare: {
      props: { fka: "compare" },
      note: "The three fka treatments side by side over the same states (emoji, SF Symbol monogram, SVG image, harness mark, never renamed, long names).",
    },
    inline: {
      props: { fka: "inline" },
      note: 'Default: icon + name + a muted caption-size "fka old" on the same line; it gives way before the name when space runs out. Legible with no hover, one line high, so it fits the header and sender lines.',
    },
    tooltip: {
      props: { fka: "tooltip" },
      note: "Quietest: icon + name; the former names show only on hover.",
    },
    stacked: {
      props: { fka: "stacked" },
      note: 'Icon + name over a small "fka old" line: most legible, but two rows high, which a 26px header control row does not fit.',
    },
  },
});
