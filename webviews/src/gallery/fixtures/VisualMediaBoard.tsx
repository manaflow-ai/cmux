// l10n-allow-file: gallery fixtures (portable visual previews), not shipped UI.
import { useEffect, useMemo, useState } from "react";

export type MediaPreview = {
  id: string;
  title: string;
  description: string;
  format: string;
  kind: "still" | "sequence";
  frames: string[];
};

function fixtureImage(colors: [string, string, string], shift: number, label: string): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 400">
    <defs>
      <linearGradient id="background" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="${colors[0]}"/><stop offset=".52" stop-color="${colors[1]}"/><stop offset="1" stop-color="${colors[2]}"/>
      </linearGradient>
      <filter id="soft"><feGaussianBlur stdDeviation="28"/></filter>
    </defs>
    <rect width="640" height="400" fill="url(#background)"/>
    <circle cx="${150 + shift}" cy="120" r="116" fill="${colors[2]}" opacity=".46" filter="url(#soft)"/>
    <circle cx="${470 - shift}" cy="284" r="150" fill="${colors[0]}" opacity=".5" filter="url(#soft)"/>
    <path d="M0 310 C120 ${230 - shift / 2} 208 ${390 + shift / 2} 332 286 S520 ${220 - shift / 3} 640 310 V400 H0Z" fill="#0b1020" opacity=".26"/>
    <path d="M0 334 C130 ${285 + shift / 3} 236 ${410 - shift / 3} 382 316 S540 ${260 + shift / 2} 640 328" fill="none" stroke="#fff" stroke-opacity=".34" stroke-width="3"/>
    <rect x="28" y="28" width="${180 + label.length * 3}" height="34" rx="17" fill="#fff" fill-opacity=".12"/>
    <text x="46" y="50" fill="#fff" fill-opacity=".88" font-family="system-ui, sans-serif" font-size="14">${label}</text>
  </svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

export const MEDIA_PREVIEWS: MediaPreview[] = [
  {
    id: "aurora-still",
    title: "Aurora still",
    description: "A single frame for checking image fit, tint, and contrast.",
    format: "static · SVG fixture",
    kind: "still",
    frames: [fixtureImage(["#101b44", "#2367a6", "#e27f9b"], 0, "reference still")],
  },
  {
    id: "webp-loop",
    title: "Soft frame loop",
    description: "Three frames switch in place without changing the card size.",
    format: "sequence · WebP target",
    kind: "sequence",
    frames: [
      fixtureImage(["#251447", "#8b4f9f", "#f0a36a"], -28, "frame 01"),
      fixtureImage(["#1d2756", "#4d8ac3", "#f3d38b"], 0, "frame 02"),
      fixtureImage(["#172d43", "#278a84", "#f1ca7b"], 28, "frame 03"),
    ],
  },
  {
    id: "gif-loop",
    title: "Pulse loop",
    description: "A faster loop for motion, loading, and pause-state review.",
    format: "sequence · GIF/APNG target",
    kind: "sequence",
    frames: [
      fixtureImage(["#24103a", "#9b2f6d", "#f46f83"], -44, "pulse 01"),
      fixtureImage(["#1c1844", "#6540b4", "#e780d3"], -10, "pulse 02"),
      fixtureImage(["#101d42", "#2370b6", "#71d4dc"], 24, "pulse 03"),
      fixtureImage(["#102d37", "#268e8a", "#d9e57f"], 52, "pulse 04"),
    ],
  },
  {
    id: "wide-art",
    title: "Wide artwork",
    description: "A panoramic crop for checking contain versus cover behavior.",
    format: "static · AVIF target",
    kind: "still",
    frames: [fixtureImage(["#172033", "#395783", "#d0a66e"], 54, "wide reference")],
  },
  {
    id: "portrait-art",
    title: "Portrait crop",
    description: "A tall subject that exposes accidental stretching immediately.",
    format: "static · JPEG XL target",
    kind: "still",
    frames: [fixtureImage(["#25152c", "#9a536a", "#f1c27d"], -18, "portrait reference")],
  },
  {
    id: "dark-motion",
    title: "Dark motion",
    description: "Low-light frames for checking hover chrome and readable labels.",
    format: "sequence · WebM target",
    kind: "sequence",
    frames: [
      fixtureImage(["#070b18", "#152a45", "#456f88"], -18, "dark 01"),
      fixtureImage(["#070b18", "#1b3c56", "#5b8e9b"], 8, "dark 02"),
      fixtureImage(["#070b18", "#254f5a", "#8bbf9b"], 34, "dark 03"),
    ],
  },
];

function PreviewCard({ item, autoplay, fit }: { item: MediaPreview; autoplay: boolean; fit: "cover" | "contain" }) {
  const [frame, setFrame] = useState(0);
  const [paused, setPaused] = useState(false);
  const hasMotion = item.frames.length > 1;

  useEffect(() => {
    setFrame(0);
    setPaused(false);
  }, [item.id]);

  useEffect(() => {
    if (!autoplay || paused || !hasMotion) return;
    const timer = window.setInterval(() => setFrame((current) => (current + 1) % item.frames.length), 900);
    return () => window.clearInterval(timer);
  }, [autoplay, hasMotion, item.frames.length, paused]);

  return (
    <article className="cmux-gallery-media-card">
      <button
        className="cmux-gallery-media-stage"
        type="button"
        onClick={() => hasMotion && setPaused((current) => !current)}
        aria-label={hasMotion ? `${item.title}, ${paused ? "resume" : "pause"} preview` : `${item.title} preview`}
        aria-pressed={hasMotion ? paused : undefined}
      >
        <img src={item.frames[frame]} alt="" style={{ objectFit: fit }} />
        <span className="cmux-gallery-media-stage-top" aria-hidden="true">
          <span className="cmux-gallery-media-kind">
            {item.kind === "still" ? "Static" : paused ? "Paused" : "Playing"}
          </span>
          {hasMotion ? (
            <span className="cmux-gallery-media-count">
              {frame + 1}/{item.frames.length}
            </span>
          ) : null}
        </span>
        {hasMotion ? (
          <span className="cmux-gallery-media-stage-hint" aria-hidden="true">
            {paused ? "click to play" : "click to pause"}
          </span>
        ) : null}
      </button>
      <div className="cmux-gallery-media-copy">
        <div className="cmux-gallery-media-title-row">
          <strong>{item.title}</strong>
          <span className="cmux-gallery-media-format">{item.format}</span>
        </div>
        <p>{item.description}</p>
      </div>
    </article>
  );
}

export function VisualMediaBoard() {
  const [filter, setFilter] = useState<"all" | MediaPreview["kind"]>("all");
  const [autoplay, setAutoplay] = useState(true);
  const [fit, setFit] = useState<"cover" | "contain">("cover");
  const items = useMemo(
    () => (filter === "all" ? MEDIA_PREVIEWS : MEDIA_PREVIEWS.filter((item) => item.kind === filter)),
    [filter],
  );
  const motionCount = MEDIA_PREVIEWS.filter((item) => item.kind === "sequence").length;

  return (
    <div className="cmux-gallery-media-board">
      <div className="cmux-gallery-media-toolbar" role="toolbar" aria-label="Preview board controls">
        <fieldset className="cmux-gallery-media-filter">
          <legend className="cmux-gallery-media-visually-hidden">Preview type</legend>
          {(["all", "still", "sequence"] as const).map((value) => (
            <button
              key={value}
              type="button"
              className={filter === value ? "is-active" : ""}
              onClick={() => setFilter(value)}
            >
              {value === "all" ? "All" : value === "still" ? "Static" : "Motion"}
            </button>
          ))}
        </fieldset>
        <button className="cmux-gallery-media-action" type="button" onClick={() => setAutoplay((current) => !current)}>
          {autoplay ? "Pause previews" : "Play previews"}
        </button>
        <fieldset className="cmux-gallery-media-filter">
          <legend className="cmux-gallery-media-visually-hidden">Preview fit</legend>
          {(["cover", "contain"] as const).map((value) => (
            <button
              key={value}
              type="button"
              className={fit === value ? "is-active" : ""}
              onClick={() => setFit(value)}
            >
              {value}
            </button>
          ))}
        </fieldset>
        <span className="cmux-gallery-media-count-label">
          {items.length} previews · {motionCount} motion
        </span>
      </div>
      <p className="cmux-gallery-media-help">
        A quick visual board for stills and motion. The fixtures are portable inline SVG, so they can be reviewed
        without a network or binary asset store; the same cards can take real AVIF, WebP, GIF, APNG, or video URLs.
      </p>
      <div className="cmux-gallery-media-grid">
        {items.map((item) => (
          <PreviewCard key={item.id} item={item} autoplay={autoplay} fit={fit} />
        ))}
      </div>
    </div>
  );
}
