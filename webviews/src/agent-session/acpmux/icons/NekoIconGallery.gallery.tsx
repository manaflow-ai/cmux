// l10n-allow-file: gallery comparison, not shipped UI.
import type { CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { AlertCircle, Check, Copy, Pin, Retry, Speaker, Spinner } from "../conversation/icons";
import { Icon } from "./Icon";
import { IconsProvider } from "./IconsContext";
import { bundledIconPack, overlaidIconPack } from "./iconPack";
import candidate from "./nekoCandidate.json";
import type { IconPack } from "./types";

// All candidate assets and packs are imported only by this gallery entry.
import noto from "../../../../../design/icons/neko-candidates/noto-emoji/cat.svg?url";
import fluent from "../../../../../design/icons/neko-candidates/fluent-emoji/cat-flat.svg?url";
import lucide from "../../../../../design/icons/neko-candidates/lucide/cat.svg?url";

const candidatePack = overlaidIconPack(bundledIconPack, candidate as IconPack);
// Explicit provider identity keeps a host's debug family out of the baseline comparison.
const baselinePack = { ...bundledIconPack };
const sets = {
  noto: {
    title: "Noto Emoji",
    license: "Apache-2.0",
    image: noto,
    note: "Expressive cat artwork; no action or spinner glyphs. Colored silhouette differs from the default line family.",
  },
  fluent: {
    title: "Fluent Emoji Flat",
    license: "MIT",
    image: fluent,
    note: "Cat mascot artwork; no semantic action or spinner glyphs. Broad fills differ from our utility strokes.",
  },
  lucide: {
    title: "Lucide Cat",
    license: "ISC + MIT",
    image: lucide,
    note: "Monochrome line cat; the utility family has ordinary actions but no neko action treatment.",
  },
  authored: {
    title: "cmux Cat + fill-ins",
    license: "First-party",
    image: "",
    note: "Copy and pin experiments only. Other actions and working/status marks retain default geometry. Not enabled.",
  },
} as const;
type SetName = keyof typeof sets;
const samples = [
  ["action.copy", "Copy"],
  ["action.reload", "Retry"],
  ["media.audio", "Speak"],
  ["bookmark", "Bookmark"],
  ["action.pin", "Pin"],
  ["action.more", "More"],
] as const;

function TokenRow({ experimental = false }: { experimental?: boolean }) {
  return (
    <IconsProvider pack={experimental ? candidatePack : baselinePack}>
      <div style={{ display: "flex", gap: 16 }} data-token-row={experimental ? "candidate" : "default"}>
        {samples.map(([name, label]) => (
          <span key={name} style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
            <Icon name={name} size={16} />
            <span style={{ fontSize: 10 }}>{label}</span>
          </span>
        ))}
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <Spinner size={16} loading />
          <span style={{ fontSize: 10 }}>Working</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <Check size={16} />
          <span style={{ fontSize: 10 }}>Success</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <AlertCircle size={16} />
          <span style={{ fontSize: 10 }}>Error</span>
        </span>
      </div>
    </IconsProvider>
  );
}

function NekoIconGallery({ mode = "light", set = "authored" }: { mode?: "light" | "dark"; set?: SetName }) {
  const art = sets[set];
  const dark = mode === "dark";
  return (
    <div
      data-neko-gallery={set}
      data-mode={mode}
      style={
        {
          background: dark ? "#1b1d22" : "#f7f7f5",
          color: dark ? "#d9dce1" : "#383a40",
          colorScheme: mode,
          "--agent-accent": dark ? "#c3a4ff" : "#7a45d6",
          padding: 24,
          minHeight: 420,
          display: "grid",
          gap: 20,
          fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
        } as CSSProperties
      }
    >
      <div>
        <strong style={{ fontSize: 15 }}>{art.title} beside cmux default</strong>
        <div style={{ fontSize: 12, marginTop: 6 }}>{art.license} · Gallery only · Actual 16 CSS px glyphs</div>
      </div>
      <div style={{ display: "grid", gap: 12 }}>
        <span style={{ fontSize: 12 }}>Default shared tokens</span>
        <TokenRow />
      </div>
      {set === "authored" ? (
        <div style={{ display: "grid", gap: 12 }}>
          <span style={{ fontSize: 12 }}>Candidate · 2/6 actions · 0/1 spinner · 0/2 status marks</span>
          <TokenRow experimental />
        </div>
      ) : (
        <div style={{ display: "flex", gap: 24, alignItems: "center", minHeight: 60 }}>
          {[16, 24, 32].map((size) => (
            <div key={size} style={{ display: "grid", justifyItems: "center", gap: 8 }}>
              <img
                src={art.image}
                alt={`${art.title} cat`}
                width={size}
                height={size}
                style={{ filter: set === "lucide" && dark ? "invert(1)" : undefined }}
              />
              <span style={{ fontSize: 10 }}>{size} px</span>
            </div>
          ))}
          <span style={{ fontSize: 12 }}>
            0/6 neko actions · 0/1 spinner · 0/2 status marks
            <br />
            Missing glyphs are not replaced with cat faces.
          </span>
        </div>
      )}
      <div style={{ fontSize: 12, maxWidth: 570, lineHeight: 1.5 }}>{art.note}</div>
      <div style={{ borderTop: "1px solid currentColor", paddingTop: 12, display: "grid", gap: 12 }}>
        <span style={{ fontSize: 11 }}>
          Actual transcript components (baseline; migration owned by the shared icon pass)
        </span>
        <div style={{ display: "flex", gap: 16 }}>
          <Copy />
          <Retry />
          <Speaker />
          <Pin />
          <Spinner loading />
          <Check />
          <AlertCircle />
        </div>
      </div>
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.neko-icon-family",
  title: "Neko icon family comparison",
  area: "Agent pane",
  height: 480,
  covers: ["agent-session/acpmux/icons/Icon.tsx#Icon", "agent-session/acpmux/conversation/icons.tsx"],
  load: async () => NekoIconGallery,
  variants: Object.fromEntries(
    Object.keys(sets).flatMap((set) =>
      ["light", "dark"].map((mode) => [
        `${set}-${mode}`,
        {
          note: "Round 1: unapproved candidate, beside default; see neko-evaluation.md for capture-based verdict.",
          props: { mode, set },
        },
      ]),
    ),
  ),
});
