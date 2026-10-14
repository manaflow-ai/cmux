// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useEffect, useRef } from "react";
import { componentEntry } from "../gallery/format";
import { StatusGlyph } from "./StatusGlyph";
import { STATUS_GLYPHS, type StatusGlyphName } from "./statusGlyphs.generated";

const NAMES = Object.keys(STATUS_GLYPHS) as StatusGlyphName[];

// A stand-in wallpaper: a busy photo-like gradient, as the update surfaces' sheet uses.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

/** One drawing at its own pixel size, blown up so its pixels show: `pixels` 10 is the 1x pixel art,
 * 20 the 2x master. */
function Pixels({ name, pixels, zoom }: { name: StatusGlyphName; pixels: 10 | 20; zoom: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext("2d");
    if (!element || !context) return;
    context.clearRect(0, 0, pixels, pixels);
    context.fillStyle = getComputedStyle(element).color;
    const art = STATUS_GLYPHS[name];
    context.fill(new Path2D(pixels === 10 ? art.x1 : art.master), "evenodd");
  }, [name, pixels]);
  return (
    <canvas
      ref={canvas}
      className="status-glyphs-pixels"
      width={pixels}
      height={pixels}
      style={{ color: STATUS_GLYPHS[name].tint, width: pixels * zoom, height: pixels * zoom }}
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
            <th scope="col">10 pt</th>
            <th scope="col">In a row</th>
            <th scope="col">1x pixels</th>
            <th scope="col">2x pixels</th>
          </tr>
        </thead>
        <tbody>
          {NAMES.map((name) => (
            <tr key={name}>
              <th scope="row">
                <strong>{name}</strong>
                <span>{STATUS_GLYPHS[name].for}</span>
              </th>
              <td className="status-glyphs-live">
                <StatusGlyph name={name} label={name} />
              </td>
              <td>
                <span className="status-glyphs-row">
                  <StatusGlyph name={name} />
                  <span>Fix the sidebar hover card</span>
                </span>
              </td>
              <td>
                <Pixels name={name} pixels={10} zoom={6} />
              </td>
              <td>
                <Pixels name={name} pixels={20} zoom={3} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
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
      note: "The six static glyphs for the Static status mode (Reduce Motion): live at 10 pt, in a row, and their 1x pixel art and 2x drawing blown up. Switch the gallery to light or dark for each appearance.",
      props: {},
    },
    wallpaper: {
      note: "The same sheet on a wallpaper.",
      props: { onWallpaper: true },
    },
  },
});
