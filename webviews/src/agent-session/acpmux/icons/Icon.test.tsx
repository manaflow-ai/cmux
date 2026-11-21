import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Icon } from "./Icon";
import { IconsProvider } from "./IconsContext";
import { Copy, Retry, Pin, Spinner, PlayTriangle, StopSquare } from "../conversation/icons";
import { iconLayers } from "./iconLayers";
import { rowIconSize } from "./iconSize";
import type { IconPack } from "./types";

function renderedStrokes(markup: string): number[] {
  const width = Number(markup.match(/width="([\d.]+)"/)?.[1]);
  const span = Number(markup.match(/viewBox="([^"]+)"/)?.[1].split(" ")[2]);
  return [...markup.matchAll(/stroke-width="([\d.]+)"/g)].map((m) => (Number(m[1]) * width) / span);
}

for (const size of [12, 14, 16, 20]) {
  for (const props of [{}, { row: true }, { row: true, fit: true }]) {
    test(`line weight stays consistent at ${size}px in ${JSON.stringify(props)}`, () => {
      for (const name of ["action.copy", "tool.shell", "machine.mac", "device.phone", "action.retry"]) {
        const strokes = renderedStrokes(renderToStaticMarkup(<Icon name={name} size={size} {...props} />));
        expect(strokes.length).toBeGreaterThan(0);
        for (const stroke of strokes) expect(stroke).toBeCloseTo((1.25 * size) / 16, 4);
      }
    });
  }
}

test("transcript aliases follow the active pack, styles and selected form", () => {
  const pack: IconPack = {
    id: "test",
    version: 1,
    grid: 24,
    icons: {
      "action.copy": { line: [{ op: "stroke", d: "M3 12L21 12", w: 2 }], solid: [] },
      "action.pin": { line: [], solid: [{ op: "fill", d: "M3 3L21 3L12 21Z" }] },
    },
  };
  const html = renderToStaticMarkup(
    <IconsProvider pack={pack}>
      <Copy className="copy-mark" style={{ opacity: 0.5 }} />
      <Pin filled />
    </IconsProvider>,
  );
  expect(html).toContain('d="M3 12L21 12"');
  expect(html).toContain('d="M3 3L21 3L12 21Z"');
  expect(html).toContain('class="copy-mark"');
  expect(html).toContain("opacity:0.5");
});

test("Retry has its own joined-arrow drawing and decorative accessibility", () => {
  const html = renderToStaticMarkup(<Retry />);
  expect(html).toContain('data-icon="action.retry"');
  expect(html).toContain('aria-hidden="true"');
  expect(html).not.toContain("icon.missing");
  expect(renderedStrokes(html)).toEqual([1.25, 1.25]);
});

test("row labels choose the icon scale, with larger artwork retained", () => {
  expect([10, 11, 12, 13, 14, 15, 16].map(rowIconSize)).toEqual([12, 14, 14, 16, 16, 16, 20]);
  expect(rowIconSize(24)).toBe(29);
});

test("normalization preserves knockout clearance and the animated spinner", () => {
  const html = renderToStaticMarkup(
    <svg>
      {iconLayers(
        [
          { op: "stroke", d: "M0 0L24 24", w: 1.5 },
          { op: "clearStroke", d: "M0 24L24 0", w: 3 },
          { op: "stroke", d: "M0 24L24 0", w: 1.5 },
        ],
        "clearance",
        1.875,
      )}
    </svg>,
  );
  expect(html).toContain('stroke="black" stroke-width="3.75"');
  expect(html.match(/stroke-width="1.875"/g)).toHaveLength(2);
  const spinner = renderToStaticMarkup(<Spinner />);
  expect(spinner).toContain('stroke-width="1.5"');
  expect(spinner).toContain('class="cv-spinner__arc"');
});

test("media play and stop retain their filled silhouette", () => {
  for (const glyph of [<PlayTriangle key="play" />, <StopSquare key="stop" />]) {
    const html = renderToStaticMarkup(glyph);
    expect(html).toMatch(/<path d="[^"]+" fill="currentColor"/);
  }
});
