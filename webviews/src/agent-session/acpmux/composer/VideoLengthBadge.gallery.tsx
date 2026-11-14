// l10n-allow-file: gallery fixtures (row labels and file names), not shipped UI.
// Every video tile's length badge at every size the pane draws one (Leo, 2026-11-11, of a 36 px
// chip whose "0:32" broke onto two lines over its play glyph: "this preview, the time is on the wrong
// place ... we should never be able to see this"). One stage holds the four size classes, each at a
// portrait, square and wide shape, with a short, a long and an hour-long length:
//
//   composer strip chip (64 tall)  composer/VideoAttachmentTile.tsx in the attachment strip
//   chip in the text (48 tall)     the same tile placed in the prompt's text (markdownField.css)
//   sent tile (120 tall)           conversation/SentVideoTile.tsx in a sent prompt's row
//   queued tile (36 tall)          QueuedImages.tsx under a queued prompt
//
// The variants are the looks compared for the rule (composer/videoLengthFit.ts); `corner-or-hidden`
// is the one shipped. The others restyle the same components with a gallery-only sheet.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../../gallery/fixtures/videoPoster";
import { SentVideoTile } from "../conversation/SentVideoTile";
import { QueuedImages } from "../QueuedImages";
import { useT } from "../i18n";
import { VideoAttachmentTile } from "./VideoAttachmentTile";
import { frameName } from "./videoPrompt";
import { videoRatio } from "./videoShape";

type Look = "corner-or-hidden" | "before" | "always" | "small-glyph";
type Props = { look: Look };

/// The lengths every size is drawn with: m:ss, mm:ss and h:mm:ss.
const LENGTHS = [
  { label: "0:32", ms: 32_000 },
  { label: "12:34", ms: 754_000 },
  { label: "1:02:03", ms: 3_723_000 },
] as const;

/// Portrait (a phone recording, Leo's chip), square and wide (a screen recording).
const SHAPES = [
  { name: "portrait", width: 1080, height: 1440 },
  { name: "square", width: 1080, height: 1080 },
  { name: "wide", width: 1920, height: 1080 },
] as const;

const WIDE_POSTER = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;

/// A poster of `width`×`height`: the recording's frame for the wide one, a drawn frame otherwise (a
/// queued tile takes its width from its poster's shape).
function poster(width: number, height: number): string {
  if (width > height) return WIDE_POSTER;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width / 6}" height="${height / 6}">` +
    `<rect width="100%" height="100%" fill="#2b3442"/>` +
    `<rect x="10%" y="8%" width="80%" height="10%" rx="4" fill="#4b5a70"/>` +
    `<rect x="10%" y="24%" width="80%" height="44%" rx="6" fill="#8aa0bd"/>` +
    `<rect x="10%" y="74%" width="56%" height="6%" rx="3" fill="#4b5a70"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/// The looks compared, as overrides of the shipped sheet. `before` is the rule before this change: the
/// length could break onto lines and draw over the glyph. `always` keeps it on one line in the corner
/// at every size, over the glyph where there is no room. `small-glyph` gives tiles under the strip's
/// height a 16 px glyph and the length a 2 px inset, so more of them have room for it.
const LOOKS = `
[data-look="before"] .acpmux-attachment-video-length:not(.acpmux-queued-video),
[data-look="before"] .cv-user__video-length {
  display: block !important;
  white-space: normal;
  font-size: var(--text-detail);
  line-height: 1.4;
}
[data-look="before"] .acpmux-queued-video-time,
[data-look="always"] .acpmux-queued-video-time {
  display: inline !important;
}
[data-look="always"] .acpmux-attachment-video-length:not(.acpmux-queued-video),
[data-look="always"] .cv-user__video-length {
  display: block !important;
}
[data-look="small-glyph"] .acpmux-md-inline-chip .acpmux-attachment-video-play {
  width: 16px;
  height: 16px;
}
[data-look="small-glyph"] .acpmux-md-inline-chip .acpmux-attachment-video-play svg {
  width: 10px;
  height: 10px;
}
[data-look="small-glyph"] .acpmux-md-inline-chip .acpmux-attachment-video-length {
  right: 2px;
  bottom: 2px;
}
.vlb-stage {
  display: grid;
  gap: 16px;
  padding: 16px;
  color: var(--agent-text);
  font-size: var(--text-detail);
}
.vlb-row {
  display: grid;
  gap: 6px;
}
.vlb-tiles {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 12px;
}
.vlb-label {
  color: var(--agent-muted);
}
.vlb-strip {
  --acpmux-attach-height: 64px;
  --acpmux-attach-radius: 6px;
  display: flex;
}
.vlb-inline {
  --acpmux-attach-radius: 6px;
  display: inline-flex;
  border-radius: 6px;
}
.vlb-sent {
  display: flex;
  max-width: none;
  margin: 0;
}
`;

function Tiles({ size }: { size: "strip" | "inline" | "sent" | "queued" }) {
  const t = useT();
  const tiles = SHAPES.flatMap((shape) =>
    LENGTHS.map((length) => ({ shape, length, key: `${shape.name}-${length.label}` })),
  );
  return (
    <div className="vlb-tiles">
      {tiles.map(({ shape, length, key }) => {
        const name = `Recording ${key}.mov`;
        const src = poster(shape.width, shape.height);
        const data = { "data-size": size, "data-shape": shape.name, "data-length": length.label };
        if (size === "queued")
          return (
            <span key={key} {...data}>
              <QueuedImages
                t={t}
                images={[
                  {
                    id: key,
                    mimeType: "image/jpeg",
                    name: frameName(name, 0),
                    width: shape.width,
                    height: shape.height,
                    src,
                  },
                ]}
                videos={[{ name, durationMs: length.ms, frames: 1 }]}
              />
            </span>
          );
        if (size === "sent") {
          const height = 120;
          return (
            <span key={key} className="cv-user__images vlb-sent" {...data}>
              <SentVideoTile
                video={{
                  name,
                  path: `/Users/dev/Movies/${name}`,
                  length: length.label,
                  width: shape.width,
                  height: shape.height,
                  poster: { id: `${key}:poster`, mimeType: "image/jpeg", src },
                }}
                width={Math.round(height * videoRatio(shape))}
                height={height}
              />
            </span>
          );
        }
        const tile = (
          <VideoAttachmentTile
            name={name}
            video={{ durationMs: length.ms, width: shape.width, height: shape.height, poster: src, frames: [] }}
            shape={videoRatio(shape)}
            remove={null}
            onPlay={() => {}}
          />
        );
        return size === "strip" ? (
          <span key={key} className="vlb-strip" {...data}>
            {tile}
          </span>
        ) : (
          <span key={key} className="acpmux-md-inline-chip vlb-inline" data-chip="strip" {...data}>
            {tile}
          </span>
        );
      })}
    </div>
  );
}

const ROWS = [
  { size: "strip", label: "Composer strip chip, 64 tall" },
  { size: "inline", label: "Chip in the prompt's text, 48 tall (Leo's 36 × 48 chip is the first)" },
  { size: "sent", label: "Sent prompt's tile, 120 tall" },
  { size: "queued", label: "Queued prompt's tile, 36 tall" },
] as const;

function VideoLengthBadgeStage({ look }: Props) {
  const [sheet] = useState(LOOKS);
  return (
    <div className="vlb-stage" data-look={look}>
      <style>{sheet}</style>
      {ROWS.map((row) => (
        <div key={row.size} className="vlb-row">
          <div className="vlb-label">{row.label}: portrait, square, wide × 0:32, 12:34, 1:02:03</div>
          <Tiles size={row.size} />
        </div>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.video-length-badge",
  title: "Video length badge, every tile size",
  area: "Agent pane",
  pane: true,
  height: 720,
  covers: ["agent-session/acpmux/composer/videoLengthFit.ts"],
  load: async () => VideoLengthBadgeStage,
  variants: {
    "corner-or-hidden": {
      note: "Shipped. Leo, 2026-11-11: \"this preview, the time is on the wrong place ... we should never be able to see this\". The length is one line in the bottom-right corner, at the caption size on the composer's chips; where the tile has no room for it inside its edge and clear of the play glyph, it is not drawn (the tile's label and tooltip still say it). The chips in the text (48 tall) never have that room; a queued tile too narrow keeps its glyph alone.",
      props: { look: "corner-or-hidden" },
    },
    before: {
      note: "The rule before: the length could break onto lines, and on a narrow chip it drew over the play glyph in the tile's middle, as in Leo's screenshot (the chip in the text, first tile).",
      props: { look: "before" },
    },
    always: {
      note: "Compared: one line in the corner at every size, never hidden. On the chips in the text and the narrow queued tiles it covers the glyph or runs past the tile's edge.",
      props: { look: "always" },
    },
    "small-glyph": {
      note: "Compared: the chip in the text gets a 16 px glyph and a 2 px inset for the length, so its wide shapes have room for a short length. Busier on a 48 px chip, and still nothing on the narrow ones.",
      props: { look: "small-glyph" },
    },
  },
});
