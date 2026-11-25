// l10n-allow-file: gallery fixtures, not shipped UI.
// Wallpaper lighting (glass.css WALLPAPER LIGHTING; appearance.wallpaperLighting). Leo, 2026-11-17:
// "anyways i was thinking about how like if you have wallpapers... what if there could be effects that
// stream out to other parts of hte ui? i mean since we have so much glass anyways... what if you almost
// treat the background wallpaper like a light source? lighting inside cmux!?"
//
// The stage is a window over a wallpaper: the sidebar, two panes and the composer, each on the glass
// material. The three wallpapers are painted by cmux-motion's light_fixtures example, which also writes
// what the app's light field reads from each (fixtures/wallpaperLight.json): the key light's direction
// from the window, the rim, bloom and tint colors and their strengths. Nothing here computes light;
// the variants only scale what Rust found, to pick how loud it should be.
import { type CSSProperties, useEffect } from "react";
import aurora from "../../gallery/fixtures/assets/wallpaper-light-aurora.png?inline";
import day from "../../gallery/fixtures/assets/wallpaper-light-day.png?inline";
import dusk from "../../gallery/fixtures/assets/wallpaper-light-dusk.png?inline";
import fields from "../../gallery/fixtures/wallpaperLight.json";
import { componentEntry } from "../../gallery/format";
import "../../agent-session/acpmux/composerStates.css";

type Scheme = "dark" | "light";
type Wallpaper = "dusk" | "aurora" | "day";
/** off: today's glass. rim: the lit edge only. bloom: plus the composer's glow. full: plus the glass
 * tint (ships). vivid: full at 1.6x, the loudest it could be. */
type Look = "off" | "rim" | "bloom" | "full" | "vivid";
type Props = { wallpaper: Wallpaper; look: Look; scheme: Scheme };

const PICTURES: Record<Wallpaper, string> = { dusk, aurora, day };
type Field = {
  style: { dx: number; dy: number; rimAlpha: number; bloomAlpha: number; tintShare: number };
  rim: number[];
  bloom: number[];
  tint: number[];
};
const FIELDS = fields as unknown as Record<Wallpaper, Field>;

const SCHEMES: Record<Scheme, Record<string, string>> = {
  dark: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(30, 31, 36)",
    "--cmux-text": "rgb(236, 236, 240)",
    "--cmux-text-secondary": "rgba(236, 236, 240, 0.72)",
  },
  light: {
    "--cmux-surface-background": "transparent",
    "--cmux-surface-solid": "rgb(250, 250, 252)",
    "--cmux-text": "rgb(28, 28, 32)",
    "--cmux-text-secondary": "rgba(28, 28, 32, 0.7)",
  },
};

const rgb = (c: number[]) => `rgb(${c.map((v) => Math.round(v * 255)).join(" ")})`;

/** The variables WebTheme.swift sends for a light field, scaled by the look. */
function lightVariables(field: Field, look: Look): Record<string, string> {
  const gain = look === "vivid" ? 1.6 : 1;
  const { dx, dy, rimAlpha, bloomAlpha, tintShare } = field.style;
  return {
    "--wl-dx": String(dx),
    "--wl-dy": String(dy),
    "--wl-rim": rgb(field.rim),
    "--wl-rim-alpha": String(Math.min(1, rimAlpha * gain)),
    "--wl-bloom": rgb(field.bloom),
    "--wl-bloom-alpha": String(look === "rim" ? 0 : Math.min(1, bloomAlpha * gain)),
    "--wl-tint": rgb(field.tint),
    "--wl-tint-share": String(look === "full" || look === "vivid" ? Math.min(1, tintShare * gain) : 0),
  };
}

function useStage({ wallpaper, look, scheme }: Props): void {
  useEffect(() => {
    const root = document.documentElement;
    const saved = root.getAttribute("style");
    for (const [name, value] of Object.entries(SCHEMES[scheme])) root.style.setProperty(name, value);
    root.style.colorScheme = scheme;
    // The window's art behind the see-through page: in the app it is native, under the page.
    root.style.setProperty("background", `url("${PICTURES[wallpaper]}") center / cover no-repeat fixed`, "important");
    root.setAttribute("data-cmux-see-through", "");
    root.toggleAttribute("data-wallpaper-light", look !== "off");
    if (look !== "off") {
      for (const [name, value] of Object.entries(lightVariables(FIELDS[wallpaper], look))) {
        root.style.setProperty(name, value);
      }
    }
    return () => {
      root.removeAttribute("data-cmux-see-through");
      root.removeAttribute("data-wallpaper-light");
      if (saved === null) root.removeAttribute("style");
      else root.setAttribute("style", saved);
    };
  }, [wallpaper, look, scheme]);
}

const PANE: CSSProperties = {
  position: "relative",
  boxSizing: "border-box",
  borderRadius: "var(--ds-radius-card)",
  padding: "var(--ds-space-3)",
  color: "var(--cmux-text)",
  fontSize: "var(--text-body)",
  lineHeight: 1.5,
  overflow: "hidden",
};

const SIDEBAR_ROWS = ["cmux", "Wallpaper lighting", "Gamma audit", "Nightly", "Review queue"];
const LEFT_TEXT =
  "The glass picks up the light of the picture behind it: the edge that faces the bright part of the wallpaper catches its color, and the composer glows with it. ";
const RIGHT_TEXT = "cargo test -p cmux-motion light ... 25 passed. ";

function WallpaperLightGallery(props: Props) {
  useStage(props);
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "180px 1fr 256px",
        gap: "var(--ds-space-4)",
        padding: "var(--ds-space-4)",
        height: 420,
        boxSizing: "border-box",
      }}
    >
      <div className="ui-glass ui-glass-material" style={PANE}>
        {SIDEBAR_ROWS.map((row, i) => (
          <div key={row} style={{ height: 28, display: "flex", alignItems: "center", opacity: i === 1 ? 1 : 0.75 }}>
            {row}
          </div>
        ))}
      </div>
      <div className="ui-glass ui-glass-material" style={{ ...PANE, display: "flex", flexDirection: "column" }}>
        <div style={{ flex: 1, opacity: 0.9 }}>{LEFT_TEXT.repeat(3)}</div>
        <div className="acpmux-composer">
          <div
            className="ui-glass ui-glass-floats ui-glass-material acpmux-composer-box"
            style={{
              borderRadius: "var(--ds-radius-composer)",
              padding: "var(--ds-space-3)",
              minHeight: 64,
              color: "var(--cmux-text-secondary)",
              // The card ring the agent pane's own sheet (styles.css) gives the card: without it the
              // composer's box-shadow list is invalid and draws no shadow, so no bloom.
              ["--acpmux-card-ring" as string]: "inset 0 0 0 var(--cmux-hairline, 0.5px) transparent",
            }}
          >
            Message the agent…
          </div>
        </div>
      </div>
      <div className="ui-glass ui-glass-material" style={{ ...PANE, fontFamily: "ui-monospace, monospace" }}>
        {RIGHT_TEXT.repeat(6)}
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.wallpaper-light",
  title: "Wallpaper lighting",
  area: "Pages",
  experimental: true,
  height: 440,
  covers: ["ui/glass/glass.css", "agent-session/acpmux/composerStates.css"],
  load: async () => WallpaperLightGallery,
  variants: {
    "dusk-off": {
      note: "Today: the glass's white top-left light whatever the wallpaper.",
      props: { wallpaper: "dusk", look: "off", scheme: "dark" },
    },
    "dusk-rim": {
      note: "The lit edge only: each surface's edge toward the sun (upper right) catches its warm color.",
      props: { wallpaper: "dusk", look: "rim", scheme: "dark" },
    },
    "dusk-bloom": {
      note: "Rim plus the composer's bloom in the picture's most colorful color (the magenta sky).",
      props: { wallpaper: "dusk", look: "bloom", scheme: "dark" },
    },
    "dusk-full": {
      note: "Ships: rim, bloom and the glass leaning toward the picture's mean color (in linear light).",
      props: { wallpaper: "dusk", look: "full", scheme: "dark" },
    },
    "dusk-vivid": {
      note: "Full at 1.6x: the loudest it could be; the tint starts to color the text's ground.",
      props: { wallpaper: "dusk", look: "vivid", scheme: "dark" },
    },
    "aurora-full": {
      note: "Ships, aurora: the light is at the left, so the left edges catch the green and the bloom is green.",
      props: { wallpaper: "aurora", look: "full", scheme: "dark" },
    },
    "day-full": {
      note: "Ships, a bright day: a low sun at the lower left; a bright picture glows less (bloom 0.14).",
      props: { wallpaper: "day", look: "full", scheme: "dark" },
    },
    "day-full-light": {
      note: "Ships, a bright day in the light theme.",
      props: { wallpaper: "day", look: "full", scheme: "light" },
    },
  },
});
