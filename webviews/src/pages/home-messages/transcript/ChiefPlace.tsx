// The Chief's header extras on a Chief chat (the native header's, HomeHostView): its face as the app
// reads it (HomeChiefSurface: the registry picture, else the profile's text, else its picked
// character, else the name's monogram) and the location chip beside its name (ChiefTeleportChip:
// This Mac, cmux Cloud, the host, or the running move's step); a click on the chip opens the app's
// Teleport menu under it. Every word comes from the host (ChiefTeleportStrings).

/** The header avatar the host read for the shown Chief. */
export interface ChiefFace {
  conversation: string;
  /** A data URL. */
  picture?: string;
  /** The profile's text avatar (an emoji or two letters). */
  text?: string;
}

export type ChiefPlaceTone = "here" | "away" | "running" | "failed";
export type ChiefPlaceGlyph = "thisMac" | "cloud" | "host" | "moving" | "rollingBack" | "failed";

/** The location chip (ChiefTeleportChipFace). */
export interface ChiefPlace {
  conversation: string;
  tone: ChiefPlaceTone;
  text: string;
  glyph: ChiefPlaceGlyph;
  label: string;
  help: string;
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const TONES = new Set<string>(["here", "away", "running", "failed"]);
const GLYPHS = new Set<string>(["thisMac", "cloud", "host", "moving", "rollingBack", "failed"]);

/** The host's `chiefFace` event; undefined for null or a value that is not one. */
export function parseChiefFace(event: unknown): ChiefFace | undefined {
  const raw = record(event);
  const conversation = text(raw?.conversation);
  if (!raw || !conversation) return undefined;
  const picture = text(raw.picture);
  const words = text(raw.text);
  return {
    conversation,
    ...(picture?.startsWith("data:image/") ? { picture } : {}),
    ...(words ? { text: words } : {}),
  };
}

/** The host's `chiefPlace` event; undefined for null (no chip on the shown conversation). */
export function parseChiefPlace(event: unknown): ChiefPlace | undefined {
  const raw = record(event);
  const conversation = text(raw?.conversation);
  const chip = record(raw?.chip);
  const words = text(chip?.text);
  if (!conversation || !chip || !words) return undefined;
  const tone = typeof chip.tone === "string" && TONES.has(chip.tone) ? (chip.tone as ChiefPlaceTone) : "here";
  const glyph = typeof chip.glyph === "string" && GLYPHS.has(chip.glyph) ? (chip.glyph as ChiefPlaceGlyph) : "thisMac";
  return { conversation, tone, text: words, glyph, label: text(chip.label) ?? words, help: text(chip.help) ?? "" };
}

/** The place's glyph (the chip's SF Symbol: laptopcomputer, cloud, macmini, the move's arrows, the warning). */
function PlaceGlyph({ glyph }: { glyph: ChiefPlaceGlyph }) {
  const common = {
    width: 12,
    height: 12,
    viewBox: "0 0 16 16",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.4,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
  switch (glyph) {
    case "thisMac":
      return (
        <svg {...common}>
          <rect x="3" y="3.5" width="10" height="7" rx="1" />
          <path d="M1.5 12.5h13" />
        </svg>
      );
    case "cloud":
      return (
        <svg {...common}>
          <path d="M4.5 12.5h7a3 3 0 0 0 .3-6 4 4 0 0 0-7.6 1A2.5 2.5 0 0 0 4.5 12.5Z" />
        </svg>
      );
    case "host":
      return (
        <svg {...common}>
          <rect x="2" y="5" width="12" height="6" rx="1.5" />
          <path d="M5 8h2" />
        </svg>
      );
    case "rollingBack":
      return (
        <svg {...common}>
          <path d="M6 4 3 7l3 3" />
          <path d="M3 7h6.5a3.5 3.5 0 0 1 0 7H8" />
        </svg>
      );
    case "failed":
      return (
        <svg {...common}>
          <path d="M8 2.5 14 13H2Z" />
          <path d="M8 6.5v3M8 11.3v.1" />
        </svg>
      );
    default:
      return (
        <svg {...common}>
          <path d="M13 6.5A5 5 0 0 0 3.6 5M3 9.5A5 5 0 0 0 12.4 11" />
          <path d="M13 3v3.5H9.5M3 13V9.5h3.5" />
        </svg>
      );
  }
}

export interface ChiefPlaceChipProps {
  place: ChiefPlace;
  /** The click, with the chip's box in page points (the host pops its menu up under it). */
  onOpen?(anchor: { x: number; y: number; width: number; height: number }): void;
}

/** The location chip beside a Chief's name. */
export function ChiefPlaceChip({ place, onOpen }: ChiefPlaceChipProps) {
  return (
    <button
      type="button"
      className={`mt-place-chip ${place.tone}`}
      data-testid="cmux.home.chief.teleport.header"
      aria-label={place.label}
      aria-haspopup="menu"
      title={place.help}
      onClick={(event) => {
        const box = event.currentTarget.getBoundingClientRect();
        onOpen?.({ x: box.x, y: box.y, width: box.width, height: box.height });
      }}
    >
      <PlaceGlyph glyph={place.glyph} />
      <span className="mt-place-text">{place.text}</span>
      <svg
        className="mt-place-chevron"
        width="12"
        height="12"
        viewBox="0 0 12 12"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        aria-hidden
      >
        <path d="M4 5l2 2 2-2" />
      </svg>
    </button>
  );
}
