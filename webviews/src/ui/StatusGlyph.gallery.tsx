// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { useEffect, useRef } from "react";
import { componentEntry } from "../gallery/format";
import { StatusGlyph } from "./StatusGlyph";
import { STATUS_GLYPHS, STATUS_GLYPH_SETS, type StatusGlyphName } from "./statusGlyphs.generated";

/** One row of a sheet: a state, the glyph it draws and the color it is tinted with. */
type Row = { state: string; note: string; name: StatusGlyphName; tint: string };

type SetName = "static" | "codex" | "dots" | "pictograms";

/** A set that draws every state with its own glyph, idle first (the Static set and its hq#1957
 * competitors, Dots and Pictograms): each row is named for the Static state it stands in for. */
const ownGlyphs = (set: "static" | "dots" | "pictograms"): Row[] => {
  const names = (Object.keys(STATUS_GLYPHS) as StatusGlyphName[]).filter((name) => STATUS_GLYPHS[name].set === set);
  const states = (Object.keys(STATUS_GLYPHS) as StatusGlyphName[]).filter(
    (name) => STATUS_GLYPHS[name].set === "static",
  );
  return names.map((name, index) => ({
    state: states[index]!,
    note: STATUS_GLYPHS[name].for,
    name,
    tint: STATUS_GLYPHS[name].tint,
  }));
};

const SETS: Record<SetName, Row[]> = {
  static: ownGlyphs("static"),
  dots: ownGlyphs("dots"),
  pictograms: ownGlyphs("pictograms"),
  codex: Object.entries(STATUS_GLYPH_SETS.codex).map(([state, pick]) => ({
    state,
    note:
      state === "working"
        ? "work: the app's shared spinner in this grey; this still ring under Reduce Motion or Static"
        : STATUS_GLYPHS[pick.glyph].for,
    name: pick.glyph,
    tint: pick.tint,
  })),
};

// A stand-in wallpaper: a busy photo-like gradient, as the update surfaces' sheet uses.
const wallpaper = "linear-gradient(160deg, #3b5b7a 0%, #c98b5a 45%, #e7c9a0 60%, #2f4a3a 100%)";

/** One drawing at its own pixel size, blown up so its pixels show: `pixels` 10 is the 1x pixel art,
 * 20 the 2x master. */
function Pixels({ row, pixels, zoom }: { row: Row; pixels: 10 | 20; zoom: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext("2d");
    if (!element || !context) return;
    context.clearRect(0, 0, pixels, pixels);
    context.fillStyle = getComputedStyle(element).color;
    const art = STATUS_GLYPHS[row.name];
    context.fill(new Path2D(pixels === 10 ? art.x1 : art.master), "evenodd");
  }, [row, pixels]);
  return (
    <canvas
      ref={canvas}
      className="status-glyphs-pixels"
      width={pixels}
      height={pixels}
      style={{ color: row.tint, width: pixels * zoom, height: pixels * zoom }}
      aria-hidden="true"
    />
  );
}

function StatusGlyphSheet({ onWallpaper = false, set = "static" }: { onWallpaper?: boolean; set?: SetName }) {
  return (
    <div className="status-glyphs-stage" style={onWallpaper ? { backgroundImage: wallpaper } : undefined}>
      <table className="status-glyphs-sheet" data-set={set}>
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
          {SETS[set].map((row) => (
            <tr key={row.state}>
              <th scope="row">
                <strong>{row.state}</strong>
                <span>{row.note}</span>
              </th>
              <td className="status-glyphs-live">
                <StatusGlyph name={row.name} tint={row.tint} label={row.state} />
              </td>
              <td>
                <span className="status-glyphs-row">
                  <StatusGlyph name={row.name} tint={row.tint} />
                  <span>Fix the sidebar hover card</span>
                </span>
              </td>
              <td>
                <Pixels row={row} pixels={10} zoom={6} />
              </td>
              <td>
                <Pixels row={row} pixels={20} zoom={3} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default componentEntry<{ onWallpaper?: boolean; set?: SetName }>({
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
    codex: {
      note: "The Codex-like set (Leo's team, 2026-10-14): a neutral grey spinner (its still ring here), Codex's blue done dot, an attention dot for a wait (no talk bubble), a muted line shield for permission, and a red line i for an error.",
      props: { set: "codex" },
    },
    "codex-wallpaper": {
      note: "The Codex-like set on a wallpaper.",
      props: { set: "codex", onWallpaper: true },
    },
    dots: {
      note: "The Dots set (hq#1957 status glyph thunderdome, Debug only): one small dot per state, hollow while nothing needs you, solid with a bar, check or x cut out when something does. Same theme colors as the Static set.",
      props: { set: "dots" },
    },
    "dots-wallpaper": {
      note: "The Dots set on a wallpaper.",
      props: { set: "dots", onWallpaper: true },
    },
    pictograms: {
      note: "The Pictograms set (hq#1957 status glyph thunderdome, Debug only): a moon, an hourglass, a chat bubble, a padlock, a check and a warning triangle. Same theme colors as the Static set.",
      props: { set: "pictograms" },
    },
    "pictograms-wallpaper": {
      note: "The Pictograms set on a wallpaper.",
      props: { set: "pictograms", onWallpaper: true },
    },
  },
});
