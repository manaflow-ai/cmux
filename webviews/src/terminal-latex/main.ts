import katex from "katex";

type Region = { column: number; row: number; width: number; height: number };
type Equation = {
  source: string;
  display: boolean;
  regions: Region[];
  layout: Region;
  foreground?: string;
  background?: string;
};
type Preview = {
  equations: Equation[];
  cellWidth: number;
  cellHeight: number;
  paddingLeft: number;
  paddingTop: number;
  foreground: string;
  background: string;
};

/** Renders trusted-size TeX into native MathML without external resources. */
export function renderEquation(source: string, display: boolean): string | null {
  if (source.length > 4096) return null;
  try {
    return katex.renderToString(source, {
      displayMode: display,
      output: "mathml",
      throwOnError: true,
      trust: false,
      strict: "error",
      maxSize: 10,
      maxExpand: 500,
    });
  } catch {
    // Incomplete or unsupported input stays visible in the underlying terminal.
    return null;
  }
}

/** Replaces the current terminal overlay with previews from one render frame. */
export function updatePreview(preview: Preview): void {
  const root = document.getElementById("equations");
  if (!root) return;
  const fragment = document.createDocumentFragment();
  const layouts: Array<{ box: HTMLElement; math: HTMLElement }> = [];
  for (const equation of preview.equations.slice(0, 64)) {
    const html = renderEquation(equation.source, equation.display);
    if (!html) continue;
    const group = document.createElement("div");
    const color = equation.foreground ?? preview.foreground;
    const background = equation.background ?? preview.background;
    const place = (element: HTMLElement, region: Region) => {
      Object.assign(element.style, {
        position: "absolute",
        left: `${preview.paddingLeft + region.column * preview.cellWidth}px`,
        top: `${preview.paddingTop + region.row * preview.cellHeight}px`,
        width: `${region.width * preview.cellWidth}px`,
        height: `${region.height * preview.cellHeight}px`,
        backgroundColor: background,
        color,
        overflow: "hidden",
      });
    };
    for (const region of equation.regions) {
      const mask = document.createElement("div");
      place(mask, region);
      group.append(mask);
    }
    const box = document.createElement("div");
    place(box, equation.layout);
    const math = document.createElement("div");
    math.innerHTML = html;
    math.style.cssText = `position:absolute;width:max-content;font-size:${preview.cellHeight * 0.82}px;transform-origin:top left`;
    layouts.push({ box, math });
    box.append(math);
    group.append(box);
    fragment.append(group);
  }
  root.replaceChildren(fragment);
  // Measure once after insertion; never grow the terminal's grid or cover
  // adjacent prose. A multiline display block can use all its source rows.
  // ponytail: fixed source-cell footprint; taller previews require terminal reflow.
  for (const { box, math } of layouts) {
    const scale = Math.min(1, box.clientWidth / Math.max(1, math.offsetWidth), box.clientHeight / Math.max(1, math.offsetHeight));
    math.style.transform = `scale(${scale})`;
    math.style.top = `${Math.max(0, (box.clientHeight - math.offsetHeight * scale) / 2)}px`;
  }
}

if (typeof window !== "undefined") {
  Object.assign(window, { updateTerminalLatex: updatePreview });
}
