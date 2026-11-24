// l10n-allow-file: gallery fixtures (sample pictures), not shipped UI.
// The Background card's placement preview (appearance.backgroundPlacement): the chosen picture in a
// window-shaped frame, dragged into place, with Fill | Fit and Reset once it is moved. Each variant
// is live: drag the picture or press the arrow keys.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { parsePlacement, type Size } from "../backgroundPlacement";
import { BackgroundPlacementPreview } from "./BackgroundPlacementPreview";

/** A sample picture: a sky over hills with a sun, so its moves show. */
function picture(width: number, height: number): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
<defs><linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d3b6e"/><stop offset="1" stop-color="#e8a36a"/></linearGradient></defs>
<rect width="${width}" height="${height}" fill="url(#s)"/>
<circle cx="${width * 0.72}" cy="${height * 0.35}" r="${Math.min(width, height) * 0.09}" fill="#ffd87a"/>
<path d="M0 ${height * 0.8} Q ${width * 0.25} ${height * 0.6} ${width * 0.5} ${height * 0.78} T ${width} ${height * 0.7} V ${height} H 0 Z" fill="#2d4a3a"/>
</svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

type Props = { image: Size; text: string; disabled?: boolean };

function PreviewFixture({ image, text, disabled = false }: Props) {
  const [value, setValue] = useState(() => parsePlacement(text)!);
  return (
    <section className="settings-page" style={{ padding: 16 }}>
      <section className="group" data-card="backdrop">
        <BackgroundPlacementPreview
          src={picture(image.width, image.height)}
          imageSize={image}
          value={value}
          disabled={disabled}
          onPlace={setValue}
        />
      </section>
    </section>
  );
}

const wide = { width: 2400, height: 1000 };
const tall = { width: 900, height: 1400 };

export default componentEntry<Props>({
  id: "settings.background-placement",
  title: "Background: Placement Preview",
  area: "Settings",
  height: 420,
  widths: { narrow: 360, normal: 520 },
  covers: ["pages/settings/components/BackgroundPlacementPreview.tsx#BackgroundPlacementPreview"],
  load: async () => {
    // The labels come from the Settings catalog, which this component host does not load.
    const { installCatalog } = await import("../strings");
    installCatalog((await import("../generated/strings.json")).default);
    return PreviewFixture;
  },
  styles: () => import("../page.css"),
  variants: {
    "fill-centered": {
      note: "Unset: today's centered fill; no Reset.",
      props: { image: wide, text: "fill" },
    },
    "fill-moved": {
      note: "Dragged to the picture's right edge; Reset shows.",
      props: { image: wide, text: "fill 1 0.5" },
    },
    "fit-wide": {
      note: "Fit: the whole picture, bars above and below.",
      props: { image: wide, text: "fit" },
    },
    "fit-tall": {
      note: "Fit with a portrait picture, anchored left.",
      props: { image: tall, text: "fit 0 0.5" },
    },
    "fill-tall-zoomed": {
      note: "A zoom Adjust Background… set (scroll or pinch); the preview keeps it.",
      props: { image: tall, text: "fill 0.5 0.2 2" },
    },
    disabled: {
      note: "While the settings file cannot be read.",
      props: { image: wide, text: "fill 0.3 0.5", disabled: true },
    },
  },
});
