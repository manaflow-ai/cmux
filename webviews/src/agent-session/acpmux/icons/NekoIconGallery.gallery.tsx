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
    drawings: { "action.copy": earfoldCopy, "action.retry": earfoldRetry, "media.audio": earfoldSpeak },
  },
  tailterm: {
    title: "cmux Tail terminals",
    license: "First-party",
    image: "",
    note: "One contour ends in a small curl. Unapproved round 2 experiment.",
    drawings: { "action.copy": tailtermCopy, "action.retry": tailtermRetry, "media.audio": tailtermSpeak },
  },
  whisker: {
    title: "cmux Whisker edges",
    license: "First-party",
    image: "",
    note: "Short rays share an exposed edge. Higher recognition risk; unapproved round 2 experiment.",
    drawings: { "action.copy": whiskerCopy, "action.retry": whiskerRetry, "media.audio": whiskerSpeak },
  },
} as const;
type SetName = keyof typeof sets;
type Density = "compact" | "comfortable";
type UiScale = 1 | 1.25;

const DENSITY_MULTIPLIER: Record<Density, number> = { compact: 0.875, comfortable: 1 };
const UI_SCALES: readonly UiScale[] = [1, 1.25];
const DENSITIES: readonly Density[] = ["compact", "comfortable"];
const BASE = {
  rootPadding: 24,
  rootMinHeight: 420,
  rootGap: 20,
  headerMetaGap: 8,
  sectionGap: 12,
  rowGap: 16,
  itemGap: 8,
  itemWidth: 44,
  glyph: 16,
  sampleGap: 24,
  sampleMinHeight: 60,
  noteMaxWidth: 570,
  noteLineHeight: 1.5,
  footerGap: 16,
  footerBorder: 1,
  footerInset: 12,
} as const;

function px(value: number): string {
  return `calc(${value}px * var(--cmux-interface-scale, 1))`;
}

function interfaceScale(density: Density, uiScale: UiScale): number {
  return DENSITY_MULTIPLIER[density] * uiScale;
}

const samples = [
  ["action.copy", "Copy"],
  ["action.retry", "Retry"],
  ["media.audio", "Speak"],
  ["bookmark", "Bookmark"],
  ["action.pin", "Pin"],
  ["action.more", "More"],
] as const;

function TokenRow({
  experimental = false,
  drawings,
  scale,
  dark = false,
}: {
  experimental?: boolean;
  drawings?: Readonly<Record<string, string>>;
  scale: number;
  dark?: boolean;
}) {
  const glyphSize = BASE.glyph * scale;
  return (
    <IconsProvider pack={experimental ? candidatePack : baselinePack}>
      <div
        style={{ display: "flex", gap: px(BASE.rowGap) }}
        data-token-row={experimental || drawings ? "candidate" : "default"}
      >
        {samples.map(([name, label]) => (
          <span
            key={name}
            style={{ display: "grid", justifyItems: "center", gap: px(BASE.itemGap), width: px(BASE.itemWidth) }}
          >
            {drawings?.[name] ? (
              <img
                aria-hidden="true"
                data-neko-drawing={drawings[name]}
                src={drawings[name]}
                alt=""
                style={{
                  display: "block",
                  width: px(BASE.glyph),
                  height: px(BASE.glyph),
                  objectFit: "contain",
                  filter: dark ? "invert(1)" : undefined,
                }}
              />
            ) : (
              <Icon name={name} size={glyphSize} />
            )}
            <span style={{ fontSize: "var(--text-caption)" }}>{label}</span>
          </span>
        ))}
        <span style={{ display: "grid", justifyItems: "center", gap: px(BASE.itemGap), width: px(BASE.itemWidth) }}>
          <Spinner size={glyphSize} loading />
          <span style={{ fontSize: "var(--text-caption)" }}>Working</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: px(BASE.itemGap), width: px(BASE.itemWidth) }}>
          <Check size={glyphSize} />
          <span style={{ fontSize: "var(--text-caption)" }}>Success</span>
        </span>
        <span style={{ display: "grid", justifyItems: "center", gap: px(BASE.itemGap), width: px(BASE.itemWidth) }}>
          <AlertCircle size={glyphSize} />
          <span style={{ fontSize: "var(--text-caption)" }}>Error</span>
        </span>
      </div>
    </IconsProvider>
  );
}

function NekoIconGallery({
  mode = "light",
  set = "authored",
  density = "comfortable",
  uiScale = 1,
}: {
  mode?: "light" | "dark";
  set?: SetName;
  density?: Density;
  uiScale?: UiScale;
}) {
  const art = sets[set];
  const dark = mode === "dark";
  const drawings = "drawings" in art ? art.drawings : undefined;
  const scale = interfaceScale(density, uiScale);
  const glyphSize = BASE.glyph * scale;
  return (
    <div
      data-neko-gallery={set}
      data-mode={mode}
      style={
        {
          background: dark ? "#1b1d22" : "#f7f7f5",
          color: dark ? "#d9dce1" : "#383a40",
          colorScheme: mode,
          "--cmux-interface-scale": scale,
          "--agent-accent": dark ? "#c3a4ff" : "#7a45d6",
          padding: px(BASE.rootPadding),
          minHeight: px(BASE.rootMinHeight),
          display: "grid",
          gap: px(BASE.rootGap),
          fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
        } as CSSProperties
      }
    >
      <div>
        <strong style={{ fontSize: "var(--text-body)" }}>{art.title} beside cmux default</strong>
        <div style={{ fontSize: "var(--text-detail)", marginTop: px(BASE.headerMetaGap) }}>
          {art.license} · Gallery only · {density} · UI scale {uiScale} · {glyphSize}px glyphs
        </div>
      </div>
      <div style={{ display: "grid", gap: px(BASE.sectionGap) }}>
        <span style={{ fontSize: "var(--text-detail)" }}>Default shared tokens</span>
        <TokenRow scale={scale} dark={dark} />
      </div>
      {set === "authored" || drawings ? (
        <div style={{ display: "grid", gap: px(BASE.sectionGap) }}>
          <span style={{ fontSize: "var(--text-detail)" }}>
            Candidate · {drawings ? "3" : "2"}/6 actions · Shared spinner/status marks
          </span>
          <TokenRow experimental={set === "authored"} drawings={drawings} scale={scale} dark={dark} />
        </div>
      ) : (
        <div
          style={{
            display: "flex",
            gap: px(BASE.sampleGap),
            alignItems: "center",
            minHeight: px(BASE.sampleMinHeight),
          }}
        >
          {[16, 24, 32].map((size) => (
            <div key={size} style={{ display: "grid", justifyItems: "center", gap: px(BASE.itemGap) }}>
              <img
                src={art.image}
                alt={`${art.title} cat`}
                style={{
                  width: px(size),
                  height: px(size),
                  filter: set === "lucide" && dark ? "invert(1)" : undefined,
                }}
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
      <div style={{ fontSize: "var(--text-detail)", maxWidth: px(BASE.noteMaxWidth), lineHeight: BASE.noteLineHeight }}>
        {art.note}
      </div>
      <div
        style={{
          borderTop: `${px(BASE.footerBorder)} solid currentColor`,
          paddingTop: px(BASE.footerInset),
          display: "grid",
          gap: px(BASE.sectionGap),
        }}
      >
        <span style={{ fontSize: "var(--text-caption)" }}>
          Actual transcript components (baseline; migration owned by the shared icon pass)
        </span>
        <div style={{ display: "flex", gap: px(BASE.footerGap) }}>
          <Copy size={glyphSize} />
          <Retry size={glyphSize} />
          <Speaker size={glyphSize} />
          <Pin size={glyphSize} />
          <Spinner size={glyphSize} loading />
          <Check size={glyphSize} />
          <AlertCircle size={glyphSize} />
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
  covers: [
    "agent-session/acpmux/icons/Icon.tsx#Icon",
    "agent-session/acpmux/conversation/icons.tsx#Copy",
    "agent-session/acpmux/conversation/icons.tsx#Retry",
    "agent-session/acpmux/conversation/icons.tsx#Speaker",
    "agent-session/acpmux/conversation/icons.tsx#Pin",
    "agent-session/acpmux/conversation/icons.tsx#Spinner",
    "agent-session/acpmux/conversation/icons.tsx#Check",
    "agent-session/acpmux/conversation/icons.tsx#AlertCircle",
  ],
  load: async () => NekoIconGallery,
  variants: Object.fromEntries(
    (Object.keys(sets) as SetName[]).flatMap((set) =>
      DENSITIES.flatMap((density) =>
        UI_SCALES.flatMap((uiScale) =>
          (["light", "dark"] as const).map((mode) => [
            `${set}-${density}-${uiScale === 1 ? "1" : "1-25"}-${mode}`,
            {
              note: `Unapproved candidate beside default; ${density}, UI scale ${uiScale}, real DPR captures; see neko-evaluation.md for capture-based verdicts.`,
              props: { mode, set, density, uiScale },
            },
          ]),
        ),
      ),
    ),
  ),
});
