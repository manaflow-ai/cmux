// The run poster itself (posterModel.ts holds what it shows): one fixed 1200 by 800 SVG, so the
// preview in the dialog and the PNG that leaves the machine are the same markup (posterImage.ts
// draws this element's own outerHTML to a canvas), and its cost never grows with the chat.
//
// Plain SVG only, no foreignObject (WebKit taints a canvas that draws one), with literal colors
// (an SVG drawn as an image sees no page CSS) and system fonts (it loads no web font). Text is
// wrapped and clipped by the model, so every slot has a fixed size: nothing moves when the
// prompt is long or the turn edited many files.
//
// Three designs (gallery agent-pane.share-poster): glow (shipped), terminal and editorial, each
// light and dark.
import { useId } from "react";
import {
  POSTER_HEIGHT,
  POSTER_WIDTH,
  PROMPT_LINES,
  posterDuration,
  posterLink,
  wrap,
  type PosterData,
  type PosterHunk,
  type PosterLine,
} from "./posterModel";

export type PosterDesign = "glow" | "terminal" | "editorial";
export type PosterTheme = "light" | "dark";

/// The poster's words, in the pane's language (the dialog passes them from its strings).
export type PosterLabels = {
  files: (count: number) => string;
  before: string;
  after: string;
  madeWith: string;
};

type Palette = {
  background: [string, string];
  glow?: [string, string];
  fg: string;
  muted: string;
  card: string;
  cardEdge: string;
  add: string;
  addFill: string;
  del: string;
  delFill: string;
  accent: string;
};

const PALETTES: Record<PosterDesign, Record<PosterTheme, Palette>> = {
  glow: {
    dark: {
      background: ["#0b0f1e", "#17123a"],
      glow: ["#3b6cff", "#9b5cff"],
      fg: "#f4f5fb",
      muted: "#a3a8c3",
      card: "rgba(255,255,255,0.06)",
      cardEdge: "rgba(255,255,255,0.12)",
      add: "#5fe0a0",
      addFill: "rgba(95,224,160,0.12)",
      del: "#ff7b8a",
      delFill: "rgba(255,123,138,0.12)",
      accent: "#8aa4ff",
    },
    light: {
      background: ["#f7f8fd", "#ece8ff"],
      glow: ["#7ea2ff", "#c39bff"],
      fg: "#14162b",
      muted: "#5d6182",
      card: "rgba(255,255,255,0.78)",
      cardEdge: "rgba(20,22,43,0.08)",
      add: "#11865a",
      addFill: "rgba(17,134,90,0.10)",
      del: "#c8344a",
      delFill: "rgba(200,52,74,0.09)",
      accent: "#4b5fe0",
    },
  },
  terminal: {
    dark: {
      background: ["#0d0f12", "#0d0f12"],
      fg: "#e6e8eb",
      muted: "#8a9099",
      card: "#15181d",
      cardEdge: "#262a31",
      add: "#7ee787",
      addFill: "rgba(126,231,135,0.10)",
      del: "#ff8a80",
      delFill: "rgba(255,138,128,0.10)",
      accent: "#7ee787",
    },
    light: {
      background: ["#fbfbf8", "#fbfbf8"],
      fg: "#1d2025",
      muted: "#6b7079",
      card: "#ffffff",
      cardEdge: "#e3e3dc",
      add: "#1a7f37",
      addFill: "rgba(26,127,55,0.08)",
      del: "#cf222e",
      delFill: "rgba(207,34,46,0.08)",
      accent: "#1a7f37",
    },
  },
  editorial: {
    dark: {
      background: ["#121212", "#121212"],
      fg: "#f5f2ea",
      muted: "#9c978c",
      card: "rgba(245,242,234,0.05)",
      cardEdge: "rgba(245,242,234,0.10)",
      add: "#9fd88a",
      addFill: "transparent",
      del: "#f0a08a",
      delFill: "transparent",
      accent: "#f2c14e",
    },
    light: {
      background: ["#f4f1ea", "#f4f1ea"],
      fg: "#1b1a17",
      muted: "#6f6a5f",
      card: "rgba(27,26,23,0.04)",
      cardEdge: "rgba(27,26,23,0.10)",
      add: "#2f7d32",
      addFill: "transparent",
      del: "#b3402a",
      delFill: "transparent",
      accent: "#d9480f",
    },
  },
};

const SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', system-ui, sans-serif";
const MONO = "'SF Mono', ui-monospace, Menlo, Monaco, monospace";

const PAD = 64;
const INNER = POSTER_WIDTH - PAD * 2;
/// The band between the header and the footer. The prompt, the counts and the diff area sit
/// centered in it, so a short run has no empty band under it.
const CONTENT_TOP = 112;
const CONTENT_BOTTOM = 712;
/// The diff area's height when it shows pictures: the most the band leaves it.
const SHOTS_HEIGHT = 368;
const GAP = 16;
const LINE = 24;
const COLUMN = (INNER - GAP) / 2;

/// A hunk card's height: its path, its lines and a margin.
const hunkHeight = (hunk: PosterHunk) => 44 + hunk.lines.length * LINE + 14;

type Slot = { x: number; y: number; width: number; height: number };

/// Where each hunk and picture goes, from the area's top: hunks in a two-column grid whose rows
/// are as tall as their taller card, or, with pictures, hunks on the left and the pictures on the
/// right (stacked, screens being wide), or the pictures alone side by side.
function areaLayout(hunks: readonly PosterHunk[], shots: number, top: number) {
  if (shots > 0) {
    const left = hunks.slice(0, 2);
    let y = top;
    const hunkSlots = left.map((hunk) => {
      const slot = { x: PAD, y, width: COLUMN, height: hunkHeight(hunk) };
      y += slot.height + GAP;
      return slot;
    });
    const stacked = left.length > 0;
    const width = stacked ? COLUMN : (INNER - (shots - 1) * GAP) / shots;
    const height = stacked ? (SHOTS_HEIGHT - (shots - 1) * GAP) / shots : SHOTS_HEIGHT;
    const shotSlots = Array.from({ length: shots }, (_, index) => ({
      x: stacked ? PAD + COLUMN + GAP : PAD + index * (width + GAP),
      y: top + (stacked ? index * (height + GAP) : 0),
      width,
      height,
    }));
    return { hunks: hunkSlots, shots: shotSlots, height: SHOTS_HEIGHT };
  }
  const shown = hunks.slice(0, 4);
  const hunkSlots: Slot[] = [];
  let y = top;
  for (let index = 0; index < shown.length; index += 2) {
    const row = shown.slice(index, index + 2);
    const height = Math.max(...row.map(hunkHeight));
    // A hunk alone in its row takes the whole width.
    row.forEach((_, col) =>
      hunkSlots.push({ x: PAD + col * (COLUMN + GAP), y, width: row.length === 1 ? INNER : COLUMN, height }),
    );
    y += height + GAP;
  }
  return { hunks: hunkSlots, shots: [] as Slot[], height: shown.length > 0 ? y - GAP - top : 0 };
}

function Hunk({
  hunk,
  x,
  y,
  width,
  height,
  palette,
}: {
  hunk: PosterHunk;
  x: number;
  y: number;
  width: number;
  height: number;
  palette: Palette;
}) {
  const lineFill = (line: PosterLine) =>
    line.type === "add" ? palette.addFill : line.type === "del" ? palette.delFill : "transparent";
  const lineColor = (line: PosterLine) =>
    line.type === "add" ? palette.add : line.type === "del" ? palette.del : palette.muted;
  const sign = (line: PosterLine) => (line.type === "add" ? "+" : line.type === "del" ? "−" : " ");
  return (
    <g>
      <rect x={x} y={y} width={width} height={height} rx={14} fill={palette.card} stroke={palette.cardEdge} />
      <text x={x + 18} y={y + 28} fill={palette.fg} fontFamily={MONO} fontSize={15} fontWeight={600}>
        {hunk.path}
      </text>
      {hunk.lines.map((line, index) => {
        const top = y + 44 + index * LINE;
        return (
          <g key={index}>
            <rect x={x + 1} y={top} width={width - 2} height={LINE} fill={lineFill(line)} />
            <text x={x + 18} y={top + 17} fill={lineColor(line)} fontFamily={MONO} fontSize={14} xmlSpace="preserve">
              {`${sign(line)} ${line.text}`}
            </text>
          </g>
        );
      })}
    </g>
  );
}

function Shot({
  id,
  src,
  label,
  x,
  y,
  width,
  height,
  palette,
}: {
  id: string;
  src: string;
  label: string;
  x: number;
  y: number;
  width: number;
  height: number;
  palette: Palette;
}) {
  const imageTop = y + 28;
  return (
    <g>
      <text x={x} y={y + 16} fill={palette.muted} fontFamily={SANS} fontSize={15} fontWeight={600} letterSpacing={1}>
        {label.toUpperCase()}
      </text>
      <clipPath id={id}>
        <rect x={x} y={imageTop} width={width} height={height - 28} rx={12} />
      </clipPath>
      <rect x={x} y={imageTop} width={width} height={height - 28} rx={12} fill={palette.card} />
      <image
        href={src}
        x={x}
        y={imageTop}
        width={width}
        height={height - 28}
        preserveAspectRatio="xMidYMin slice"
        clipPath={`url(#${id})`}
      />
      <rect x={x} y={imageTop} width={width} height={height - 28} rx={12} fill="none" stroke={palette.cardEdge} />
    </g>
  );
}

/// The diff area: its hunks and pictures in their slots (areaLayout).
function Area({
  uid,
  data,
  palette,
  labels,
  top,
}: {
  uid: string;
  data: PosterData;
  palette: Palette;
  labels: PosterLabels;
  top: number;
}) {
  const shots = [
    ...(data.shots.before ? [{ id: `${uid}-before`, src: data.shots.before, label: labels.before }] : []),
    ...(data.shots.after ? [{ id: `${uid}-after`, src: data.shots.after, label: labels.after }] : []),
  ];
  const layout = areaLayout(data.hunks, shots.length, top);
  return (
    <>
      {layout.hunks.map((slot, index) => (
        <Hunk key={`hunk-${index}`} hunk={data.hunks[index]!} {...slot} palette={palette} />
      ))}
      {shots.map((shot, index) => (
        <Shot key={shot.id} {...shot} {...layout.shots[index]!} palette={palette} />
      ))}
    </>
  );
}

function Brand({ x, y, palette, design }: { x: number; y: number; palette: Palette; design: PosterDesign }) {
  return (
    <g>
      <rect x={x} y={y} width={30} height={30} rx={8} fill={design === "glow" ? palette.accent : palette.fg} />
      <text x={x + 9} y={y + 21} fill={palette.background[0]} fontFamily={MONO} fontSize={16} fontWeight={700}>
        {">"}
      </text>
      <text x={x + 42} y={y + 22} fill={palette.fg} fontFamily={SANS} fontSize={22} fontWeight={700}>
        cmux
      </text>
    </g>
  );
}

/// The harness, model and time on the header's right: "Claude Code · Opus 5.5 · 4m 12s".
function runLine(data: PosterData): string {
  return [data.harness, data.model, data.durationMs !== undefined ? posterDuration(data.durationMs) : undefined]
    .filter(Boolean)
    .join("  ·  ");
}

export function Poster({
  data,
  design = "glow",
  theme = "dark",
  labels,
  className,
  svgRef,
}: {
  data: PosterData;
  design?: PosterDesign;
  theme?: PosterTheme;
  labels: PosterLabels;
  className?: string;
  svgRef?: React.Ref<SVGSVGElement>;
}) {
  const palette = PALETTES[design][theme];
  // Ids unique to this poster (the gallery draws several on one page), plain enough for url(#…).
  const uid = `poster${useId().replace(/[^A-Za-z0-9_-]/g, "")}`;
  const editorial = design === "editorial";
  const terminal = design === "terminal";
  // Editorial sets the prompt larger, so fewer letters fit a line.
  const promptSize = editorial ? 44 : 38;
  const promptLines = wrap(data.prompt, editorial ? 40 : 46, PROMPT_LINES - 1);
  const promptLine = promptSize + 10;
  const run = runLine(data);
  // The content block (prompt, counts, diff area) centered in the band between header and footer.
  const shotCount = Number(Boolean(data.shots.before)) + Number(Boolean(data.shots.after));
  const areaHeight = areaLayout(data.hunks, shotCount, 0).height;
  const total = promptLines.length * promptLine + 44 + (areaHeight > 0 ? 26 + areaHeight : 0);
  const top = CONTENT_TOP + Math.max(0, (CONTENT_BOTTOM - CONTENT_TOP - total) / 2);
  const statsY = top + promptLines.length * promptLine + 44;
  return (
    <svg
      ref={svgRef}
      xmlns="http://www.w3.org/2000/svg"
      width={POSTER_WIDTH}
      height={POSTER_HEIGHT}
      viewBox={`0 0 ${POSTER_WIDTH} ${POSTER_HEIGHT}`}
      className={className}
      aria-label={data.prompt}
    >
      <defs>
        <linearGradient id={`${uid}-bg`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={palette.background[0]} />
          <stop offset="1" stopColor={palette.background[1]} />
        </linearGradient>
        {palette.glow && (
          <>
            <radialGradient id={`${uid}-glow-a`} cx="0.85" cy="0.05" r="0.55">
              <stop offset="0" stopColor={palette.glow[0]} stopOpacity={theme === "dark" ? 0.45 : 0.35} />
              <stop offset="1" stopColor={palette.glow[0]} stopOpacity={0} />
            </radialGradient>
            <radialGradient id={`${uid}-glow-b`} cx="0.05" cy="1" r="0.6">
              <stop offset="0" stopColor={palette.glow[1]} stopOpacity={theme === "dark" ? 0.35 : 0.3} />
              <stop offset="1" stopColor={palette.glow[1]} stopOpacity={0} />
            </radialGradient>
          </>
        )}
      </defs>
      <rect width={POSTER_WIDTH} height={POSTER_HEIGHT} fill={`url(#${uid}-bg)`} />
      {palette.glow && (
        <>
          <rect width={POSTER_WIDTH} height={POSTER_HEIGHT} fill={`url(#${uid}-glow-a)`} />
          <rect width={POSTER_WIDTH} height={POSTER_HEIGHT} fill={`url(#${uid}-glow-b)`} />
        </>
      )}
      {terminal && (
        <g>
          {["#ff5f57", "#febc2e", "#28c840"].map((fill, index) => (
            <circle key={fill} cx={PAD + 8 + index * 22} cy={40} r={7} fill={fill} />
          ))}
          <line x1={0} y1={72} x2={POSTER_WIDTH} y2={72} stroke={palette.cardEdge} />
        </g>
      )}
      {editorial && <rect x={0} y={0} width={10} height={POSTER_HEIGHT} fill={palette.accent} />}
      {!terminal && <Brand x={PAD} y={58} palette={palette} design={design} />}
      <text
        x={POSTER_WIDTH - PAD}
        y={terminal ? 46 : 80}
        textAnchor="end"
        fill={palette.muted}
        fontFamily={terminal ? MONO : SANS}
        fontSize={terminal ? 15 : 18}
        fontWeight={500}
      >
        {run}
      </text>
      {promptLines.map((line, index) => (
        <text
          key={index}
          x={PAD}
          y={top + promptSize + index * promptLine}
          fill={palette.fg}
          fontFamily={terminal ? MONO : SANS}
          fontSize={terminal ? 32 : promptSize}
          fontWeight={terminal ? 500 : 700}
          letterSpacing={terminal ? 0 : -0.5}
        >
          {terminal && index === 0 ? (
            <>
              <tspan fill={palette.accent}>❯</tspan>
              <tspan dx={16}>{line}</tspan>
            </>
          ) : (
            line
          )}
        </text>
      ))}
      <text x={PAD} y={statsY} fontFamily={terminal ? MONO : SANS} fontSize={editorial ? 24 : 20} fontWeight={600}>
        <tspan fill={palette.fg}>{labels.files(data.files)}</tspan>
        <tspan fill={palette.add} dx={16}>{`+${data.added}`}</tspan>
        <tspan fill={palette.del} dx={10}>{`−${data.removed}`}</tspan>
      </text>
      <Area uid={uid} data={data} palette={palette} labels={labels} top={statsY + 26} />
      <text x={PAD} y={POSTER_HEIGHT - 40} fill={palette.muted} fontFamily={SANS} fontSize={16} fontWeight={500}>
        {labels.madeWith}
      </text>
      {data.link && (
        <text
          x={POSTER_WIDTH - PAD}
          y={POSTER_HEIGHT - 40}
          textAnchor="end"
          fill={palette.accent}
          fontFamily={MONO}
          fontSize={16}
          fontWeight={600}
        >
          {posterLink(data.link)}
        </text>
      )}
    </svg>
  );
}
