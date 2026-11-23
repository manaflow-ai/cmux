// The Background card's Recent strip: the backgrounds shown before, newest first, one click each
// (Leo, 2026-11-22: "the fast-actions need to be most accessible"). A folder is a folder tile, the
// shuffle and the modes their glyph, a picture its thumbnail. The model is ../recentBackgrounds.ts.
import { useState } from "react";
import { t } from "../strings";
import type { RecentTile } from "../recentBackgrounds";

const thumbSrc = (id: string) => `backdrop/${encodeURIComponent(encodeURIComponent(id))}`;
const GLYPH: Record<Exclude<RecentTile["kind"], "picture">, string> = {
  folder: "▦",
  shuffle: "↻",
  none: "",
  mode: "◐",
};

function Thumb({ tile }: { tile: RecentTile }) {
  const [failed, setFailed] = useState(false);
  if (tile.kind !== "picture" || failed) {
    const glyph = tile.kind === "picture" ? "" : GLYPH[tile.kind];
    return (
      <span className="backdrop-thumb backdrop-none backdrop-choose" aria-hidden="true">
        {glyph}
      </span>
    );
  }
  return <img className="backdrop-thumb" alt="" src={thumbSrc(tile.id)} onError={() => setFailed(true)} />;
}

export function RecentBackgrounds({
  tiles,
  disabled = false,
  onChoose,
}: {
  tiles: readonly RecentTile[];
  disabled?: boolean;
  onChoose: (id: string) => unknown;
}) {
  if (tiles.length === 0) return null;
  const title = t("settingsWindow.backdropPicker.recentTitle");
  return (
    <div className="backdrop-recent">
      <h4 className="row-help backdrop-group-title">{title}</h4>
      <div className="backdrop-grid backdrop-recent-grid">
        {tiles.map((tile) => (
          <button
            type="button"
            key={tile.id}
            className="backdrop-tile"
            data-recent-kind={tile.kind}
            aria-label={tile.title}
            disabled={disabled}
            onClick={() => void onChoose(tile.id)}
          >
            <Thumb tile={tile} />
            <span className="backdrop-title">{tile.title}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
