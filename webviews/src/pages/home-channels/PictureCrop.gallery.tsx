// l10n-allow-file: gallery fixtures (a sample picture), not shipped UI.
// The Chief sheet shows the crop only after a file is chosen, so the page entry never reaches it.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { CENTERED, type PictureCrop as Crop } from "./picture";
import { PictureCrop } from "./PictureCrop";

type Props = { width: number; height: number; crop?: Crop };

/** A sample still: a sky, a sun and hills, so a drag or a zoom shows where the circle lands. */
function sample(width: number, height: number): string {
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">` +
    `<rect width="100%" height="100%" fill="#7fb6e8"/>` +
    `<circle cx="${width * 0.7}" cy="${height * 0.3}" r="${Math.min(width, height) * 0.12}" fill="#ffd166"/>` +
    `<ellipse cx="${width * 0.3}" cy="${height}" rx="${width * 0.55}" ry="${height * 0.45}" fill="#3c8d5a"/>` +
    `</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

function PictureCropGallery({ width, height, crop: initial = CENTERED }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [crop, setCrop] = useState(initial);
  return (
    <PictureCrop
      url={sample(width, height)}
      size={{ width, height }}
      crop={crop}
      onChange={setCrop}
      labels={{ zoom: strings.t("chief.picture.zoom"), hint: strings.t("chief.picture.cropHint") }}
    />
  );
}

export default componentEntry<Props>({
  id: "pages.home-channels.picture-crop",
  title: "Chief picture crop",
  area: "Home and Chief",
  height: 260,
  covers: ["pages/home-channels/PictureCrop.tsx#PictureCrop"],
  load: async () => PictureCropGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("./styles.css");
    await import("./ledger.css");
  },
  variants: {
    landscape: {
      note: "A wide still, centered: the circle takes its middle square.",
      props: { width: 640, height: 400 },
    },
    portrait: { note: "A tall still, centered.", props: { width: 400, height: 640 } },
    zoomed: {
      note: "Zoomed in 2.5x and moved toward the sun.",
      props: { width: 640, height: 400, crop: { zoom: 2.5, x: 0.6, y: -0.4 } },
    },
  },
});
