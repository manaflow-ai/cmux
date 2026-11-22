// The SVG refraction comparison (gallery and latency harness only; never installed by a shipped
// page). Chromium can run an SVG filter as a backdrop filter, so a glass can bend the page pixels
// behind it with feDisplacementMap instead of the lens's WebGL canvas. WebKit renders nothing for an
// SVG backdrop filter, and in the app the wallpaper is native, behind a see-through page,
// so the filter only ever bends what the page itself painted (the transcript under the composer).
// It is kept to measure against the lens: Chromium re-runs the filter for every glass on every
// frame its backdrop moves (each scroll frame), where the lens redraws one canvas. The numbers are
// in leo-workspace design/glass.md.

/** The filter's id; glass.css's `:root[data-glass-refract="svg"]` rule names it. */
export const SVG_REFRACTION_ID = "cmux-glass-refract";
export const SVG_REFRACTION_ATTRIBUTE = "data-glass-refract";

const MAP_SIZE = 128;

/** A displacement map for a rounded box stretched over any glass: red and green hold the inward
 * normal scaled by a quarter-circle bend at the rim (128 is no shift), flat in the middle. */
function displacementMap(doc: Document): string {
  const canvas = doc.createElement("canvas");
  canvas.width = MAP_SIZE;
  canvas.height = MAP_SIZE;
  const context = canvas.getContext("2d");
  if (!context) return "";
  const image = context.createImageData(MAP_SIZE, MAP_SIZE);
  const half = MAP_SIZE / 2;
  const band = MAP_SIZE * 0.22;
  for (let y = 0; y < MAP_SIZE; y++) {
    for (let x = 0; x < MAP_SIZE; x++) {
      const px = x + 0.5 - half;
      const py = y + 0.5 - half;
      // Distance in from the nearest edge, and the outward normal there.
      const dx = half - Math.abs(px);
      const dy = half - Math.abs(py);
      const inward = Math.min(dx, dy);
      const t = Math.min(1, inward / band);
      const bend = 1 - Math.sqrt(Math.max(0, t * (2 - t)));
      const nx = dx < dy ? Math.sign(px) : 0;
      const ny = dy <= dx ? Math.sign(py) : 0;
      const at = (y * MAP_SIZE + x) * 4;
      // feDisplacementMap samples at P + scale * (C - 0.5). The lens samples inward at the rim (P
      // minus the outward normal times the bend), so the map stores the normal negated.
      image.data[at] = Math.round(128 - 127 * nx * bend);
      image.data[at + 1] = Math.round(128 - 127 * ny * bend);
      image.data[at + 2] = 128;
      image.data[at + 3] = 255;
    }
  }
  context.putImageData(image, 0, 0);
  return canvas.toDataURL("image/png");
}

/** Adds the filter to the document once and turns the comparison on (`data-glass-refract="svg"`).
 * Returns the undo: the filter and the attribute go. */
export function installSvgRefraction(doc: Document = document): () => void {
  const root = doc.documentElement;
  // Installed already (a second gallery stage in the same document): one filter per id.
  if (doc.getElementById(SVG_REFRACTION_ID)) return () => undefined;
  const href = displacementMap(doc);
  const holder = doc.createElement("div");
  holder.setAttribute("aria-hidden", "true");
  holder.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
  holder.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0">
  <filter id="${SVG_REFRACTION_ID}" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
    <feImage href="${href}" x="0" y="0" width="100%" height="100%" preserveAspectRatio="none" result="map" />
    <feDisplacementMap in="SourceGraphic" in2="map" scale="44" xChannelSelector="R" yChannelSelector="G" result="bent" />
    <feGaussianBlur in="bent" stdDeviation="2" />
  </filter>
</svg>`;
  doc.body.append(holder);
  root.setAttribute(SVG_REFRACTION_ATTRIBUTE, "svg");
  return () => {
    root.removeAttribute(SVG_REFRACTION_ATTRIBUTE);
    holder.remove();
  };
}
