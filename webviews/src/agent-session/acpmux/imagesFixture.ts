// l10n-allow-file: debug fixture prompts, not shipped UI.
// A chat whose prompts carry screenshots, for `debug.agent_pane seed_rows` with `fixture: "images"`:
// the synthetic transcript (synthetic.ts) with a sent screenshot on every prompt, so the pointer can
// rest on a thumbnail while the transcript scrolls under it (Leo, 2026-11-08: "when I was hovering
// over a preview of a screenshot or whatever and then scrolling, I was getting these rapid flickers,
// re-renders of the composer area"). The pictures are drawn here: no file, no acpmux read.
import type { AcpmuxRow } from "./model";
import { syntheticRows } from "./synthetic";

const WIDTH = 1440;
const HEIGHT = 900;

/// A screenshot-shaped picture: a dark window with a light band, numbered so each prompt's differs.
function shot(turn: number): string {
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">` +
    `<rect width="100%" height="100%" fill="#1b1c20"/>` +
    `<rect x="40" y="40" width="${600 + (turn % 7) * 60}" height="200" fill="#d6d7db"/>` +
    `</svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/// Each prompt with a screenshot sent beside it, and its answer after a screenshot the agent took (a
/// tool row whose small image opens a hover preview, conversation/ToolVisualPreview.tsx).
export function imageRows(count: number): AcpmuxRow[] {
  return syntheticRows(count).flatMap((row, index): AcpmuxRow[] => {
    if (row.kind !== "user") return [row];
    const prompt: AcpmuxRow = {
      ...row,
      images: [
        {
          id: `fixture-shot-${index}`,
          mimeType: "image/svg+xml",
          name: "Screenshot.png",
          width: WIDTH,
          height: HEIGHT,
          src: shot(index),
        },
      ],
    };
    const took: AcpmuxRow = {
      id: `fixture-screenshot-${index}`,
      version: 1,
      at: row.at + 500,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          kind: "tool",
          text: "Take a screenshot",
          tool: {
            id: `fixture-screenshot-tool-${index}`,
            title: "Take a screenshot",
            kind: "other",
            status: "completed",
            startedAt: row.at + 500,
            endedAt: row.at + 900,
            images: [shot(index + 1)],
          },
        },
      ],
    };
    return [prompt, took];
  });
}
