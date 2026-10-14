// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useEffect, useRef } from "react";
import { componentEntry } from "../gallery/format";
import { StatusGlyph } from "./StatusGlyph";
import {
  DEFAULT_STATUS_GLYPH_SET,
  STATUS_GLYPH_SETS,
  STATUS_GLYPHS,
  type StatusGlyphName,
  type StatusGlyphSetName,
} from "./statusGlyphs.generated";

const NAMES = Object.keys(STATUS_GLYPHS) as StatusGlyphName[];
// The default set first, then its competitors (hq#1957 status glyph thunderdome).
const SETS = Object.keys(STATUS_GLYPH_SETS) as StatusGlyphSetName[];
const SET_TITLES: Record<StatusGlyphSetName, string> = { still: "Static", dots: "Dots", pictograms: "Pictograms" };
// A row of the sidebar for each state, to read the glyphs beside text.
const ROW_TEXT: Record<StatusGlyphName, string> = {
  idle: "Notes",
  working: "Fix the sidebar hover card",
  waiting: "Which branch should I use?",
  permission: "Allow git push?",
  done: "Release notes drafted",
  error: "Build failed",
};

// A stand-in wallpaper: a busy photo-like gradient, as the update surfaces' sheet uses.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

/** One drawing at its own pixel size, blown up so its pixels show: `pixels` 10 is the 1x pixel art,
 * 20 the 2x master. */
function Pixels({
  set,
  name,
  pixels,
  zoom,
}: {
  set: StatusGlyphSetName;
  name: StatusGlyphName;
  pixels: 10 | 20;
  zoom: number;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const art = STATUS_GLYPH_SETS[set].glyphs[name];
  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext("2d");
    if (!element || !context) return;
    context.clearRect(0, 0, pixels, pixels);
    context.fillStyle = getComputedStyle(element).color;
    context.fill(new Path2D(pixels === 10 ? art.x1 : art.master), "evenodd");
  }, [art, pixels]);
  return (
    <canvas
      ref={canvas}
      className="status-glyphs-pixels"
      width={pixels}
      height={pixels}
      style={{ color: art.tint, width: pixels * zoom, height: pixels * zoom }}
      aria-hidden="true"
    />
  );
}

function StatusGlyphSheet({ onWallpaper = false }: { onWallpaper?: boolean }) {
  return (
    <div className="status-glyphs-stage" style={onWallpaper ? { backgroundImage: wallpaper } : undefined}>
      <table className="status-glyphs-sheet">
        <thead>
          <tr>
            <th scope="col">State</th>
            {SETS.map((set) => (
              <th key={set} scope="col" data-status-glyph-set-title={set}>
                {SET_TITLES[set]}
                {set === DEFAULT_STATUS_GLYPH_SET ? " (default)" : ""}
                <span className="status-glyphs-legend">10 pt · 1x · 2x</span>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {NAMES.map((name) => (
            <tr key={name}>
              <th scope="row">
                <strong>{name}</strong>
              </th>
              {SETS.map((set) => (
                <td key={set}>
                  <span className="status-glyphs-cell" title={STATUS_GLYPH_SETS[set].glyphs[name].for}>
                    <span className="status-glyphs-live">
                      <StatusGlyph set={set} name={name} label={`${SET_TITLES[set]} ${name}`} />
                    </span>
                    <Pixels set={set} name={name} pixels={10} zoom={4} />
                    <Pixels set={set} name={name} pixels={20} zoom={2} />
                  </span>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="status-glyphs-sidebars">
        {SETS.map((set) => (
          <ul key={set} className="status-glyphs-sidebar" aria-label={SET_TITLES[set]}>
            {NAMES.map((name) => (
              <li key={name} className="status-glyphs-row">
                <StatusGlyph set={set} name={name} />
                <span>{ROW_TEXT[name]}</span>
              </li>
            ))}
          </ul>
        ))}
      </div>
    </div>
  );
}

export default componentEntry<{ onWallpaper?: boolean }>({
  id: "ui.status-glyphs",
  title: "Static status glyphs",
  area: "UI primitives",
  height: 620,
  covers: ["ui/StatusGlyph.tsx#StatusGlyph"],
  load: async () => StatusGlyphSheet,
  styles: () => Promise.all([import("./ui.css"), import("./StatusGlyph.gallery.css")]),
  variants: {
    sheet: {
      note: "The six static glyphs for the Static status mode (Reduce Motion) in each competing set (Static, the default; Dots; Pictograms), side by side: live at 10 pt with the 1x pixel art and 2x drawing blown up, then each set in sidebar rows. Switch the gallery to light or dark for each appearance.",
      props: {},
    },
    wallpaper: {
      note: "The same sheet on a wallpaper.",
      props: { onWallpaper: true },
    },
  },
});
