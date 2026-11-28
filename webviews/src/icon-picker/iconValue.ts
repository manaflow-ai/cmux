// The one icon value every object uses (plans/cmux-next/icons.md): exactly one of an emoji, an
// SF Symbol name, a raster image asset or a sanitized SVG asset. Assets are content addressed
// (`sha256-<64 hex>`) and stored once by the object's owner (the daemon's blob store for
// daemon-owned objects; its refs are `blob:sha256-<hex>`).
//
// Wire form: the existing `icon` string field (workspace-metadata-v1 and the other icon fields)
// carries the value as one string, so old readers and stored rows stay valid:
//   one RGI emoji        -> {emoji}
//   [a-z0-9.]+           -> {symbol}
//   image:sha256-<hex>   -> {image}
//   svg:sha256-<hex>     -> {svg}

export type IconValue =
  | { readonly emoji: string }
  | { readonly symbol: string }
  | { readonly image: string }
  | { readonly svg: string };

export type IconKind = "emoji" | "symbol" | "image" | "svg";

const ASSET_ID = /^sha256-[0-9a-f]{64}$/;
const SYMBOL_NAME = /^[a-z0-9]+(\.[a-z0-9]+)*$/;
/** One RGI emoji: a single code point, keycap, flag, tag, tone or ZWJ sequence. */
// Built at run time: the `v` flag (Unicode sets) postdates the TypeScript target; WebKit and
// JavaScriptCore support it.
const EMOJI = new RegExp("^\\p{RGI_Emoji}$", "v");
const MAX_EMOJI_BYTES = 32;

export function iconKind(value: IconValue): IconKind {
  if ("emoji" in value) return "emoji";
  if ("symbol" in value) return "symbol";
  if ("image" in value) return "image";
  return "svg";
}

export function isEmoji(text: string): boolean {
  return new TextEncoder().encode(text).length <= MAX_EMOJI_BYTES && EMOJI.test(text);
}

export function isAssetID(text: string): boolean {
  return ASSET_ID.test(text);
}

export function isValidIcon(value: unknown): value is IconValue {
  if (!value || typeof value !== "object") return false;
  const keys = Object.keys(value);
  if (keys.length !== 1) return false;
  const text = (value as Record<string, unknown>)[keys[0]];
  if (typeof text !== "string") return false;
  switch (keys[0]) {
    case "emoji":
      return isEmoji(text);
    case "symbol":
      return text.length <= 128 && SYMBOL_NAME.test(text);
    case "image":
    case "svg":
      return isAssetID(text);
    default:
      return false;
  }
}

/** The wire string of a value. */
export function encodeIcon(value: IconValue): string {
  if ("emoji" in value) return value.emoji;
  if ("symbol" in value) return value.symbol;
  if ("image" in value) return `image:${value.image}`;
  return `svg:${value.svg}`;
}

/** A wire `icon` string as a value; null when it is none of the four forms. */
export function decodeIcon(text: string | null | undefined): IconValue | null {
  if (!text) return null;
  for (const kind of ["image", "svg"] as const) {
    if (text.startsWith(`${kind}:`)) {
      const id = text.slice(kind.length + 1);
      return isAssetID(id) ? ({ [kind]: id } as IconValue) : null;
    }
  }
  if (isEmoji(text)) return { emoji: text };
  if (text.length <= 128 && SYMBOL_NAME.test(text)) return { symbol: text };
  return null;
}

/** A stable key for recents and equality ("emoji:👍", "symbol:star", "image:sha256-…"). */
export function iconKey(value: IconValue): string {
  const kind = iconKind(value);
  return `${kind}:${(value as Record<string, string>)[kind]}`;
}
