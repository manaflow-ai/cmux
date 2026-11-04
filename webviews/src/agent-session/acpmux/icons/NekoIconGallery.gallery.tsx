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

import earfoldCopy from "../../../../../design/icons/neko-candidates/round2/01-earfold-copy.svg?url";
import earfoldRetry from "../../../../../design/icons/neko-candidates/round2/01-earfold-retry.svg?url";
import earfoldSpeak from "../../../../../design/icons/neko-candidates/round2/01-earfold-speak.svg?url";
import tailtermCopy from "../../../../../design/icons/neko-candidates/round2/02-tailterm-copy.svg?url";
import tailtermRetry from "../../../../../design/icons/neko-candidates/round2/02-tailterm-retry.svg?url";
import tailtermSpeak from "../../../../../design/icons/neko-candidates/round2/02-tailterm-speak.svg?url";
import whiskerCopy from "../../../../../design/icons/neko-candidates/round2/03-whisker-copy.svg?url";
import whiskerRetry from "../../../../../design/icons/neko-candidates/round2/03-whisker-retry.svg?url";
import whiskerSpeak from "../../../../../design/icons/neko-candidates/round2/03-whisker-speak.svg?url";

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
  earfold: {
    title: "cmux Ear folds",
    license: "First-party",
    image: "",
    note: "An angular cue replaces part of the action silhouette. Unapproved round 2 experiment.",
    drawings: { "action.copy": earfoldCopy, "action.reload": earfoldRetry, "media.audio": earfoldSpeak },
  },
  tailterm: {
    title: "cmux Tail terminals",
    license: "First-party",
    image: "",
    note: "One contour ends in a small curl. Unapproved round 2 experiment.",
    drawings: { "action.copy": tailtermCopy, "action.reload": tailtermRetry, "media.audio": tailtermSpeak },
  },
  whisker: {
    title: "cmux Whisker edges",
    license: "First-party",
    image: "",
    note: "Short rays share an exposed edge. Higher recognition risk; unapproved round 2 experiment.",
    drawings: { "action.copy": whiskerCopy, "action.reload": whiskerRetry, "media.audio": whiskerSpeak },
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

function TokenRow({
  experimental = false,
  drawings,
}: {
  experimental?: boolean;
  drawings?: Readonly<Record<string, string>>;
}) {
  return (
    <IconsProvider pack={experimental ? candidatePack : baselinePack}>
      <div style={{ display: "flex", gap: 16 }} data-token-row={experimental || drawings ? "candidate" : "default"}>
        {samples.map(([name, label]) => (
          <span key={name} style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
            {drawings?.[name] ? (
              <span
                aria-hidden="true"
                data-neko-drawing={drawings[name]}
                style={{
                  display: "block",
                  width: 16,
                  height: 16,
                  background: "currentColor",
                  maskImage: `url(${drawings[name]})`,
                  maskSize: "contain",
                  maskRepeat: "no-repeat",
                }}
              />
            ) : (
              <Icon name={name} size={16} />
            )}
            <span style={{ fontSize: "var(--text-caption)" }}>{label}</span>
          </span>
        ))}
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <Spinner size={16} loading />
          <span style={{ fontSize: "var(--text-caption)" }}>Working</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <Check size={16} />
          <span style={{ fontSize: "var(--text-caption)" }}>Success</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: 8, width: 44 }}>
          <AlertCircle size={16} />
          <span style={{ fontSize: "var(--text-caption)" }}>Error</span>
        </span>
      </div>
    </IconsProvider>
  );
}

function NekoIconGallery({ mode = "light", set = "authored" }: { mode?: "light" | "dark"; set?: SetName }) {
  const art = sets[set];
  const dark = mode === "dark";
  const drawings = "drawings" in art ? art.drawings : undefined;
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
        <strong style={{ fontSize: "var(--text-body)" }}>{art.title} beside cmux default</strong>
        <div style={{ fontSize: "var(--text-detail)", marginTop: 8 }}>
          {art.license} · Gallery only · Actual 16 CSS px glyphs
        </div>
      </div>
      <div style={{ display: "grid", gap: 12 }}>
        <span style={{ fontSize: "var(--text-detail)" }}>Default shared tokens</span>
        <TokenRow />
      </div>
      {set === "authored" || drawings ? (
        <div style={{ display: "grid", gap: 12 }}>
          <span style={{ fontSize: "var(--text-detail)" }}>
            Candidate · {drawings ? "3" : "2"}/6 actions · Shared spinner/status marks
          </span>
          <TokenRow experimental={set === "authored"} drawings={drawings} />
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
              <span style={{ fontSize: "var(--text-caption)" }}>{size} px</span>
            </div>
          ))}
          <span style={{ fontSize: "var(--text-detail)" }}>
            0/6 neko actions · 0/1 spinner · 0/2 status marks
            <br />
            Missing glyphs are not replaced with cat faces.
          </span>
        </div>
      )}
      <div style={{ fontSize: "var(--text-detail)", maxWidth: 570, lineHeight: 1.5 }}>{art.note}</div>
      <div style={{ borderTop: "1px solid currentColor", paddingTop: 12, display: "grid", gap: 12 }}>
        <span style={{ fontSize: "var(--text-caption)" }}>
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
    (Object.keys(sets) as SetName[]).flatMap((set) =>
      (["light", "dark"] as const).map((mode) => [
        `${set}-${mode}`,
        {
          note: "Unapproved candidate beside default; see neko-evaluation.md for capture-based verdicts.",
          props: { mode, set },
        },
      ]),
    ),
  ),
});
