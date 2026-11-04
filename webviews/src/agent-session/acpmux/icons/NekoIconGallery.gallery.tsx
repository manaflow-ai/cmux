// l10n-allow-file: gallery fixtures (icon comparison), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { CSSProperties } from "react";
import { Icon } from "./Icon";
import { bundledIconPack, nekoFillInIconPack, nekoIconPack } from "./iconPack";
import { IconsProvider } from "./IconsContext";
import { Spinner } from "../conversation/icons";

type Mode = "light" | "dark";
type SetName = "default" | "cat-accent" | "neko-fill-ins" | "neko-curated";

const ACTIONS = [
  ["action.copy", "Copy"],
  ["action.reload", "Retry"],
  ["bookmark", "Bookmark"],
  ["action.pin", "Pin"],
  ["action.more", "More"],
] as const;

const PALETTE: Record<Mode, { background: string; foreground: string; muted: string; accent: string }> = {
  light: { background: "#f7f7f5", foreground: "#252525", muted: "#74746f", accent: "#7a45d6" },
  dark: { background: "#1b1d22", foreground: "#e5e7eb", muted: "#9ca3af", accent: "#c3a4ff" },
};

function NekoIconGallery({ mode = "light", set = "neko-curated" }: { mode?: Mode; set?: SetName }) {
  const palette = PALETTE[mode];
  const provider =
    set === "neko-curated" || set === "neko-fill-ins" ? (
      <IconsProvider pack={set === "neko-curated" ? nekoIconPack : nekoFillInIconPack}>
        <Samples palette={palette} set={set} />
      </IconsProvider>
    ) : (
      <IconsProvider pack={bundledIconPack} accent={set === "cat-accent" ? "cat" : "none"}>
        <Samples palette={palette} set={set} />
      </IconsProvider>
    );
  return (
    <div
      style={{
        background: palette.background,
        color: palette.foreground,
        colorScheme: mode,
        // Keep Cat accent layers independent of the host page's accent while comparing themes.
        "--agent-accent": palette.accent,
        display: "grid",
        gap: 14,
        padding: 24,
        borderRadius: 12,
        minHeight: 156,
        fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
      } as CSSProperties}
      data-neko-gallery={set}
      data-mode={mode}
    >
      {provider}
    </div>
  );
}

function Samples({ palette, set }: { palette: (typeof PALETTE)[Mode]; set: SetName }) {
  return (
    <>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 16 }}>
        <div>
          <div style={{ fontSize: 13, fontWeight: 650 }}>Message action row</div>
          <div style={{ color: palette.muted, fontSize: 11, marginTop: 3 }}>
            {set === "neko-curated"
              ? "Neko: 40 / 331 token drawings"
              : set === "neko-fill-ins"
                ? "Candidate fill-ins: 2 / 331 token drawings"
                : set === "cat-accent"
                  ? "Existing Cat accent"
                  : "Shipped default"}
          </div>
        </div>
        <span style={{ color: palette.muted, fontSize: 11 }}>16 px / 1x</span>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 9 }}>
        {ACTIONS.map(([name, label]) => (
          <span key={name} style={{ display: "grid", gap: 4, justifyItems: "center", color: palette.foreground }}>
            <span
              style={{
                display: "grid",
                placeItems: "center",
                width: 28,
                height: 28,
                borderRadius: 7,
                background: modeSurface(palette.background),
              }}
              title={label}
            >
              <Icon name={name} size={16} />
            </span>
            <span style={{ color: palette.muted, fontSize: 9 }}>{label}</span>
          </span>
        ))}
        <span style={{ display: "grid", gap: 4, justifyItems: "center", color: palette.foreground }}>
          <span
            style={{
              display: "grid",
              placeItems: "center",
              width: 28,
              height: 28,
              borderRadius: 7,
              background: modeSurface(palette.background),
            }}
            title="Working"
          >
            <Spinner size={16} loading />
          </span>
          <span style={{ color: palette.muted, fontSize: 9 }}>Working</span>
        </span>
      </div>
      <div style={{ color: palette.muted, fontSize: 10, lineHeight: 1.35 }}>
        Neko keeps the shared line weight and spacing. Only the curated cat cues change; status and
        spinner geometry stay on the settled shared tokens until a matching drawing clears review.
      </div>
    </>
  );
}

function modeSurface(background: string) {
  return background === PALETTE.dark.background ? "#292d35" : "#ffffff";
}

export default componentEntry({
  id: "agent-pane.neko-icon-family",
  title: "Neko icon family",
  area: "Agent pane",
  height: 230,
  covers: ["agent-session/acpmux/icons/Icon.tsx#Icon", "agent-session/acpmux/icons/iconPack.ts"],
  load: async () => NekoIconGallery,
  variants: {
    "default-light": {
      note: "Round 0 · 0/6 action cues · baseline shared pack in light mode.",
      props: { mode: "light", set: "default" },
    },
    "default-dark": {
      note: "Round 0 · 0/6 action cues · baseline shared pack in dark mode.",
      props: { mode: "dark", set: "default" },
    },
    "cat-accent-light": {
      note: "Round 1 · 0/6 action cues · existing authored Cat accents, light mode; natural on nouns, absent on actions.",
      props: { mode: "light", set: "cat-accent" },
    },
    "cat-accent-dark": {
      note: "Round 1 · 0/6 action cues · existing authored Cat accents, dark mode; natural on nouns, absent on actions.",
      props: { mode: "dark", set: "cat-accent" },
    },
    "neko-fill-ins-light": {
      note: "Round 2a · 2/6 action cues · authored copy and pin fill-ins only, light mode; candidate comparison.",
      props: { mode: "light", set: "neko-fill-ins" },
    },
    "neko-fill-ins-dark": {
      note: "Round 2a · 2/6 action cues · authored copy and pin fill-ins only, dark mode; candidate comparison.",
      props: { mode: "dark", set: "neko-fill-ins" },
    },
    "neko-curated-light": {
      note: "Round 2 · 2/6 action cues · 40/331 glyph coverage; 8.7/10 taste fit at 1x/2x, light mode. Shipped cues are copy and pin only.",
      props: { mode: "light", set: "neko-curated" },
    },
    "neko-curated-dark": {
      note: "Round 2 · 2/6 action cues · 40/331 glyph coverage; 8.7/10 taste fit at 1x/2x, dark mode. Shipped cues are copy and pin only.",
      props: { mode: "dark", set: "neko-curated" },
    },
  },
});
