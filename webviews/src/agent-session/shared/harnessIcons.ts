// A harness's own icon (user 12922): acpmux resolves one per harness (`iconSpec` on each
// `_acpmux/harnesses` entry, cmux-tui/crates/acpmux/src/config/harness_icon.rs): the icon its
// profile sets (an agent mark, an emoji, an SF Symbol or an image), else the mark of the agent
// its command runs, else a monogram in a hue stable for its id. The page keeps the last list it
// read here, so every AgentMark given a harness id draws that icon with no prop threading.

export type HarnessIconSource = "profile" | "id" | "command" | "family" | "default";

export type HarnessIconSpec =
  | { kind: "brand"; brand: string; source: HarnessIconSource }
  | { kind: "glyph"; name: string; source: HarnessIconSource }
  | { kind: "emoji"; text: string; source: HarnessIconSource }
  /** `text` and `hue`: the monogram a page that cannot draw SF Symbols shows instead. */
  | { kind: "symbol"; name: string; text: string; hue: number; source: HarnessIconSource }
  | { kind: "image"; mime: "image/png" | "image/svg+xml"; data: string; source: HarnessIconSource }
  | { kind: "monogram"; text: string; hue: number; source: HarnessIconSource };

const SOURCES = new Set(["profile", "id", "command", "family", "default"]);
const str = (value: unknown, max = 256): value is string =>
  typeof value === "string" && value.length > 0 && value.length <= max;
const hueOf = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 && value < 360 ? value : undefined;

/** The `iconSpec` of one `_acpmux/harnesses` entry, or undefined when it is malformed. */
export function parseHarnessIconSpec(value: unknown): HarnessIconSpec | undefined {
  if (!value || typeof value !== "object") return undefined;
  const v = value as Record<string, unknown>;
  const source = (SOURCES.has(v.source as string) ? v.source : "default") as HarnessIconSource;
  switch (v.kind) {
    case "brand":
      return str(v.brand, 64) ? { kind: "brand", brand: v.brand, source } : undefined;
    case "glyph":
      return v.name === "terminal" || v.name === "generic" ? { kind: "glyph", name: v.name, source } : undefined;
    case "emoji":
      return str(v.text, 32) ? { kind: "emoji", text: v.text, source } : undefined;
    case "symbol": {
      const hue = hueOf(v.hue);
      return str(v.name, 128) && str(v.text, 4) && hue !== undefined
        ? { kind: "symbol", name: v.name, text: v.text, hue, source }
        : undefined;
    }
    case "image":
      return (v.mime === "image/png" || v.mime === "image/svg+xml") && str(v.data, 400_000)
        ? { kind: "image", mime: v.mime, data: v.data, source }
        : undefined;
    case "monogram": {
      const hue = hueOf(v.hue);
      return str(v.text, 4) && hue !== undefined ? { kind: "monogram", text: v.text, hue, source } : undefined;
    }
    default:
      return undefined;
  }
}

/** A `data:` URL of an image icon (the pages' CSP allows `data:` images only). */
export function harnessIconImageURL(spec: Extract<HarnessIconSpec, { kind: "image" }>): string {
  return `data:${spec.mime};base64,${spec.data}`;
}

/** The monogram disc's colors for `hue` on a light or dark surface. */
export function monogramColors(hue: number, dark: boolean): { background: string; color: string } {
  return dark
    ? { background: `hsl(${hue} 45% 38%)`, color: "#fff" }
    : { background: `hsl(${hue} 55% 46%)`, color: "#fff" };
}

// Replaced, never mutated, on each change: the map is the useSyncExternalStore snapshot, so a
// compiled (memoized) component that reads it re-renders when an icon changes.
let icons: ReadonlyMap<string, HarnessIconSpec> = new Map();
const listeners = new Set<() => void>();

const same = (a: HarnessIconSpec | undefined, b: HarnessIconSpec | undefined) =>
  a === b || (!!a && !!b && JSON.stringify(a) === JSON.stringify(b));

/**
 * Keeps the icons of a harness list the page read: a later list replaces the icon of each harness
 * it names (a removed harness keeps its last icon, so its old chats still draw it). Listeners run
 * only when an icon changed.
 */
export function rememberHarnessIcons(entries: readonly { id: string; iconSpec?: HarnessIconSpec }[]): void {
  let next: Map<string, HarnessIconSpec> | undefined;
  for (const { id, iconSpec } of entries) {
    if (!iconSpec || same(icons.get(id), iconSpec)) continue;
    next ??= new Map(icons);
    next.set(id, iconSpec);
  }
  if (!next) return;
  icons = next;
  listeners.forEach((notify) => notify());
}

/** The icon acpmux resolved for harness `id`, if the page has read one (outside render). */
export function harnessIcon(id: string | undefined): HarnessIconSpec | undefined {
  return id ? icons.get(id) : undefined;
}

export function subscribeHarnessIcons(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Every remembered icon, by harness id: the useSyncExternalStore snapshot render reads. */
export const harnessIconsSnapshot = (): ReadonlyMap<string, HarnessIconSpec> => icons;
