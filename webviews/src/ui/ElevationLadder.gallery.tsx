// l10n-allow-file: gallery labels and fixture content are public-safe sample UI.
// The elevation ladder (experiments.elevationLadder, ui/elevationLadder.css) with the switch on, as the
// host sets it on the root: its four layers side by side over a busy page (tooltip 6px on the chip
// glass with the lightest lift, menu and popover 12px on their glass with a lift off the page, sheet
// 12px on the sheet veil with a further lift, fullscreen 16px on the chrome glass with the biggest
// lift), in dark and light; and the popover's arrow as a smooth notch in its own outline, on each of
// its four sides, pointing at its anchor.
import { useLayoutEffect, useState, type CSSProperties, type ReactNode } from "react";
import { componentEntry } from "../gallery/format";
import { ELEVATION_LADDER_ATTRIBUTE } from "./elevationLadder";
import { Popover, type PopoverProps } from "./Popover";

type Scheme = "dark" | "light";
type Props = { scene: "layers" | "notch"; scheme: Scheme };

/** The theme tokens each scheme sets on the root, as the host's theme does. */
const SCHEMES: Record<Scheme, Record<string, string>> = {
  dark: {
    "color-scheme": "dark",
    "--cmux-surface-solid": "rgb(28, 29, 33)",
    "--cmux-text": "rgb(236, 236, 240)",
    "--cmux-text-secondary": "rgba(236, 236, 240, 0.66)",
  },
  light: {
    "color-scheme": "light",
    "--cmux-surface-solid": "rgb(250, 250, 252)",
    "--cmux-text": "rgb(28, 28, 32)",
    "--cmux-text-secondary": "rgba(28, 28, 32, 0.62)",
  },
};
/** A busy page under the glass: colour fields and lines of text, so the frost and lift both show. */
const PAGE: Record<Scheme, string> = {
  dark: "radial-gradient(circle at 18% 30%, rgb(236 92 60 / 70%), transparent 40%), radial-gradient(circle at 72% 70%, rgb(70 120 240 / 70%), transparent 45%), rgb(18 18 22)",
  light:
    "radial-gradient(circle at 18% 30%, rgb(255 150 110 / 75%), transparent 40%), radial-gradient(circle at 72% 70%, rgb(120 170 255 / 75%), transparent 45%), rgb(240 240 244)",
};

/** Turns the ladder on and applies the scheme for as long as the stage shows. */
function useStage(scheme: Scheme): void {
  useLayoutEffect(() => {
    const root = document.documentElement;
    const tokens = SCHEMES[scheme];
    root.setAttribute(ELEVATION_LADDER_ATTRIBUTE, "");
    for (const [name, value] of Object.entries(tokens)) root.style.setProperty(name, value);
    return () => {
      root.removeAttribute(ELEVATION_LADDER_ATTRIBUTE);
      for (const name of Object.keys(tokens)) root.style.removeProperty(name);
    };
  }, [scheme]);
}

const muted: CSSProperties = { color: "var(--cmux-text-secondary)", fontSize: "var(--text-caption)" };

function Backdrop({ scheme, children }: { scheme: Scheme; children: ReactNode }) {
  return (
    <div
      style={{
        position: "relative",
        minHeight: "100%",
        boxSizing: "border-box",
        padding: 32,
        background: PAGE[scheme],
        color: "var(--cmux-text)",
        fontFamily: "var(--font-ui)",
        fontSize: "var(--text-control)",
      }}
    >
      <div aria-hidden="true" style={{ position: "absolute", inset: 0, overflow: "hidden", opacity: 0.5, padding: 16 }}>
        {Array.from({ length: 24 }, (_, index) => (
          <div key={index} style={{ whiteSpace: "nowrap", lineHeight: "var(--text-control--line-height)" }}>
            {"The page under every floating layer keeps its text and colour, frosted where the glass lies. ".repeat(4)}
          </div>
        ))}
      </div>
      <div style={{ position: "relative" }}>{children}</div>
    </div>
  );
}

const LAYERS = [
  { step: "tooltip", name: "Tooltip", spec: "6px corner, lightest lift, chip glass", width: 160, height: 36 },
  {
    step: "popover",
    name: "Menu and popover",
    spec: "12px corner, lift off the page, menu and popover glass",
    width: 200,
    height: 160,
  },
  { step: "sheet", name: "Sheet", spec: "12px corner, further lift, sheet veil", width: 220, height: 200 },
  { step: "fullscreen", name: "Fullscreen", spec: "16px corner, biggest lift, chrome glass", width: 260, height: 240 },
] as const;

function Layers() {
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 32, flexWrap: "wrap" }}>
      {LAYERS.map((layer) => (
        <div key={layer.step} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <div
            className="ui-glass"
            data-elevation={layer.step}
            style={{
              width: layer.width,
              height: layer.height,
              boxSizing: "border-box",
              padding: layer.step === "tooltip" ? "var(--ds-space-2) var(--ds-space-3)" : 16,
            }}
          >
            {layer.name}
          </div>
          <div style={{ width: layer.width, ...muted }}>{layer.spec}</div>
        </div>
      ))}
    </div>
  );
}

const SIDES: { side: NonNullable<PopoverProps["side"]>; label: string; place: CSSProperties }[] = [
  { side: "bottom", label: "Notch on top", place: { gridColumn: 2, gridRow: 1 } },
  { side: "inline-end", label: "Notch on the left", place: { gridColumn: 1, gridRow: 2 } },
  { side: "inline-start", label: "Notch on the right", place: { gridColumn: 3, gridRow: 2 } },
  { side: "top", label: "Notch at the bottom", place: { gridColumn: 2, gridRow: 3 } },
];

function NotchSides() {
  const [anchors, setAnchors] = useState<Partial<Record<string, HTMLElement | null>>>({});
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "1fr 1fr 1fr",
        gridTemplateRows: "repeat(3, 1fr)",
        alignItems: "center",
        justifyItems: "center",
        minHeight: 400,
      }}
    >
      {SIDES.map(({ side, label, place }) => (
        <div key={side} style={place}>
          <span
            ref={(node) => {
              if (node && anchors[side] !== node) setAnchors((all) => ({ ...all, [side]: node }));
            }}
            className="ui-glass"
            data-elevation="tooltip"
            style={{ display: "inline-block", padding: "var(--ds-space-1) var(--ds-space-2)" }}
          >
            Anchor
          </span>
          <Popover
            open={anchors[side] != null}
            onOpenChange={() => undefined}
            anchor={anchors[side] ?? null}
            label={label}
            side={side}
            flip={false}
            initialFocus={false}
            finalFocus={false}
            notch
          >
            <div style={{ padding: "var(--ds-space-1) var(--ds-space-2)", maxWidth: 200 }}>
              <div style={{ fontWeight: "var(--weight-emphasis)" }}>{label}</div>
              <div style={muted}>One outline: the fill, frost, rim and lift follow the notch.</div>
            </div>
          </Popover>
        </div>
      ))}
    </div>
  );
}

function ElevationLadderGallery({ scene, scheme }: Props) {
  useStage(scheme);
  return <Backdrop scheme={scheme}>{scene === "layers" ? <Layers /> : <NotchSides />}</Backdrop>;
}

export default componentEntry<Props>({
  id: "ui.elevation-ladder",
  title: "Elevation ladder",
  area: "Pages",
  experimental: true,
  height: 520,
  keywords: ["elevation", "material", "shadow", "lift", "popover arrow", "notch", "experiments.elevationLadder"],
  covers: ["ui/elevationLadder.ts", "ui/NotchOutline.tsx#useNotchOutline", "ui/notchPath.ts", "ui/Popover.tsx#Popover"],
  styles: () => import("./ui.css"),
  load: async () => ElevationLadderGallery,
  variants: {
    "four-layers-dark": {
      note: "The four layers side by side over a busy dark page: tooltip 6px with the lightest lift on the chip glass, menu and popover 12px lifted off the page, sheet 12px lifted further on the sheet veil, fullscreen 16px with the biggest lift on the chrome glass.",
      props: { scene: "layers", scheme: "dark" },
    },
    "four-layers-light": {
      note: "The same four layers over a busy light page.",
      props: { scene: "layers", scheme: "light" },
    },
    "popover-notch-sides": {
      note: "A popover's arrow as a smooth notch in its own outline on each side, pointing at its anchor: the flat edge curves into the notch and rounds over its tip, and the fill, frost, hairline and lift are one shape.",
      props: { scene: "notch", scheme: "dark" },
    },
    "popover-notch-sides-light": {
      note: "The notch on each side over a light page.",
      props: { scene: "notch", scheme: "light" },
    },
  },
});
