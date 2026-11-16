// l10n-allow-file: gallery fixtures, not shipped UI.
// Floating UI at a larger Text Size (Leo, 2026-11-12: "evidently you zoom in and it doesn't really,
// you know, it doesn't follow, right?"). Text Size is not a page zoom: the App writes
// `--cmux-interface-scale` and the type tokens grow with it, so a popover, card or chip framed in px
// literals keeps its size while its label outgrows it. Each variant draws four floating surfaces with
// their real metrics (the context ring's card, the header tool preview, the selection's Reply chip
// and the Base picker popover) at one Text Size, framed one of three ways:
//   before: the px literals they had (the label clips or runs out of its frame);
//   width:  only the width follows (gaps, insets and the chip's height stay, the name still runs on);
//   ships:  width, gaps, insets and heights follow (`--ui-px`, ui/popupSurface.css), each label
//           ellipsizes inside its own box, and a max size bounds the frame to the window.
import type { CSSProperties, ReactNode } from "react";
import { componentEntry } from "../gallery/format";

type Scheme = "dark" | "light";
type Look = "before" | "width" | "ships";
type Props = { look: Look; scheme: Scheme; size: number };

const SCHEMES: Record<
  Scheme,
  { page: string; surface: string; text: string; muted: string; edge: string; accent: string }
> = {
  dark: {
    page: "rgb(24, 24, 28)",
    surface: "rgb(40, 41, 47)",
    text: "rgb(236, 236, 240)",
    muted: "rgba(236, 236, 240, 0.6)",
    edge: "rgba(255, 255, 255, 0.14)",
    accent: "rgb(10, 132, 255)",
  },
  light: {
    page: "rgb(242, 242, 246)",
    surface: "rgb(255, 255, 255)",
    text: "rgb(28, 28, 32)",
    muted: "rgba(28, 28, 32, 0.6)",
    edge: "rgba(0, 0, 0, 0.12)",
    accent: "rgb(0, 122, 255)",
  },
};

/** A frame length: a px literal before, else at the interface scale where `look` lets it follow. */
function frame(px: number, look: Look, part: "width" | "inner"): string {
  if (look === "ships" || (look === "width" && part === "width")) return `calc(${px} * var(--ui-px))`;
  return `${px}px`;
}

const clip = (look: Look): CSSProperties =>
  look === "ships"
    ? { minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }
    : { whiteSpace: "nowrap" };

function Surface({
  look,
  children,
  width,
  style,
}: {
  look: Look;
  children: ReactNode;
  width: number;
  style?: CSSProperties;
}) {
  return (
    <div
      style={{
        boxSizing: "border-box",
        width: frame(width, look, "width"),
        maxWidth: look === "ships" ? "calc(100% - 16px)" : undefined,
        overflow: look === "ships" ? "hidden" : undefined,
        padding: frame(8, look, "inner"),
        borderRadius: "var(--ui-popup-radius, 8px)",
        background: "var(--tsf-surface)",
        boxShadow:
          "0 0 0 0.5px var(--tsf-edge), var(--elevation-2, 0 2px 6px color-mix(in srgb, black 11%, transparent))",
        ...style,
      }}
    >
      {children}
    </div>
  );
}

function Label({ children }: { children: ReactNode }) {
  return <div style={{ color: "var(--tsf-muted)", fontSize: "var(--tsf-caption)", marginBottom: 8 }}>{children}</div>;
}

function TextSizeFollowGallery({ look, scheme, size }: Props) {
  const colors = SCHEMES[scheme];
  const scale = size / 12;
  const stage = {
    // The App writes the scale on <html>; the stage sets it and `--ui-px` on its own box so each
    // variant is its Text Size whatever the gallery's.
    "--cmux-interface-scale": String(scale),
    "--ui-px": `calc(1px * ${scale})`,
    "--tsf-surface": colors.surface,
    "--tsf-edge": colors.edge,
    "--tsf-muted": colors.muted,
    "--tsf-body": `calc(13px * ${scale})`,
    "--tsf-caption": `calc(11px * ${scale})`,
    colorScheme: scheme,
    background: colors.page,
    color: colors.text,
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
    fontSize: "var(--tsf-body)",
    lineHeight: 1.35,
    minHeight: "100%",
    boxSizing: "border-box",
    padding: 20,
    display: "grid",
    gridTemplateColumns: "repeat(2, minmax(0, 1fr))",
    gap: 24,
    alignContent: "start",
  } as CSSProperties;
  return (
    <div style={stage} data-look={look} data-text-size={size}>
      <section>
        <Label>Context card (contextCard.css, 260)</Label>
        <Surface look={look} width={260}>
          <div style={{ color: "var(--tsf-muted)", fontSize: "var(--tsf-caption)", ...clip(look) }}>Context window</div>
          <div style={{ fontWeight: 600, ...clip(look) }}>148,212 of 200,000 tokens used</div>
          <div
            style={{
              marginTop: frame(6, look, "inner"),
              height: frame(4, look, "inner"),
              borderRadius: 999,
              background: colors.edge,
            }}
          >
            <div style={{ width: "74%", height: "100%", borderRadius: 999, background: colors.accent }} />
          </div>
        </Surface>
      </section>
      <section>
        <Label>Header tool preview (HeaderToolPreview.tsx, 176)</Label>
        <Surface look={look} width={176}>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              gap: frame(8, look, "inner"),
              minWidth: 0,
            }}
          >
            <span style={{ fontWeight: 600, fontSize: "var(--tsf-caption)", ...clip(look) }}>Split Right Browser</span>
            <kbd style={{ font: "inherit", fontSize: "var(--tsf-caption)", color: "var(--tsf-muted)", flex: "none" }}>
              ⌘⇧B
            </kbd>
          </div>
          <div
            style={{
              color: "var(--tsf-muted)",
              fontSize: "var(--tsf-caption)",
              ...clip(look),
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            localhost:5173/settings/appearance
          </div>
        </Surface>
      </section>
      <section>
        <Label>Selection Reply chip (conversation.css, 28 tall)</Label>
        <div
          style={{
            display: "inline-flex",
            alignItems: "center",
            boxSizing: "border-box",
            gap: frame(4, look, "inner"),
            height: frame(28, look, "inner"),
            lineHeight: frame(20, look, "inner"),
            paddingInline: `${frame(8, look, "inner")} ${frame(12, look, "inner")}`,
            borderRadius: 8,
            background: colors.surface,
            boxShadow: `0 0 0 0.5px ${colors.edge}`,
            fontSize: `calc(14px * ${scale})`,
            whiteSpace: "nowrap",
            ...(look === "ships" ? { maxWidth: "100%", overflow: "hidden", textOverflow: "ellipsis" } : {}),
          }}
        >
          <span aria-hidden="true">↩</span>
          <span style={look === "ships" ? { minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" } : {}}>
            Reply
          </span>
        </div>
      </section>
      <section>
        <Label>Base picker (BranchBasePicker, 320)</Label>
        <Surface look={look} width={320} style={{ padding: frame(4, look, "inner") }}>
          {[
            ["origin/feat-cmux-next", "default"],
            ["lane/ui-textsize-follow-with-a-long-name", "worktree"],
            ["main", "upstream"],
          ].map(([name, reason]) => (
            <div
              key={name}
              style={{
                display: "flex",
                alignItems: "center",
                gap: frame(8, look, "inner"),
                minHeight: frame(28, look, "inner"),
                padding: `0 ${frame(8, look, "inner")}`,
              }}
            >
              <span
                style={{
                  flex: "1 1 auto",
                  minWidth: 0,
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                }}
              >
                {name}
              </span>
              <span style={{ flex: "0 1 auto", maxWidth: "55%", color: "var(--tsf-muted)", ...clip(look) }}>
                {reason}
              </span>
            </div>
          ))}
        </Surface>
      </section>
    </div>
  );
}

function variant(look: Look, size: number, scheme: Scheme, note: string) {
  return { note, props: { look, scheme, size } };
}

export default componentEntry<Props>({
  id: "ui.text-size-follow",
  title: "Floating UI follows Text Size",
  area: "UI primitives",
  height: 420,
  keywords: ["text size", "interface scale", "popover width", "zoom", "clips"],
  covers: ["ui/interfaceScale.ts"],
  load: async () => TextSizeFollowGallery,
  variants: {
    "before-16": variant(
      "before",
      16,
      "dark",
      "Before, Text Size 16: px frames keep their default size while the type grows; the card's line and the preview's name run out of their boxes.",
    ),
    "before-18": variant(
      "before",
      18,
      "dark",
      "Before, Text Size 18 (Leo's screenshot): the Reply chip's label crowds a 28 px pill and the preview's name overruns its key.",
    ),
    "width-18": variant(
      "width",
      18,
      "dark",
      "Width only: the frames widen, but the chip's height, the insets and the gaps stay at 12 pt's, so the chip still crowds its label and the rows sit cramped.",
    ),
    ships: variant(
      "ships",
      18,
      "dark",
      "Ships, Text Size 18: width, gaps, insets and heights follow --ui-px; every label ellipsizes in its own box and a max size holds the frame inside the window.",
    ),
    "ships-light": variant("ships", 18, "light", "Ships, light theme."),
    "ships-16": variant("ships", 16, "dark", "Ships, Text Size 16."),
    "ships-12": variant(
      "ships",
      12,
      "light",
      "Ships at the default Text Size 12: the same pixels as before, so nothing moves for anyone at the default.",
    ),
  },
});
