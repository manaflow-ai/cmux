// Conversation backgrounds (iOS 26 / macOS 26 Messages). See PROTOCOL.md.
// Presets mirror ConversationBackgroundLook.all in CmuxConversationCore.
import { pick, type Rng } from "./corpus";

export type BackgroundKind = "color" | "photo" | "sky" | "water" | "aurora" | "glitter";
export const BACKGROUND_KINDS: BackgroundKind[] = ["color", "photo", "sky", "water", "aurora", "glitter"];

export interface Background {
  id: string;
  kind: BackgroundKind;
  colors?: string[]; // "#RRGGBB", top to bottom
  look?: string;
  photo?: { id: string; width: number; height: number }; // media id
  luminance: number; // mean WCAG relative luminance 0..1
  setBy: string;
}

export const LOOKS: { id: string; kind: BackgroundKind; colors: string[] }[] = [
  { id: "color.ice", kind: "color", colors: ["#E8F3FF", "#B9D8F5"] },
  { id: "color.bubblegum", kind: "color", colors: ["#FFD1E8", "#F78FC4"] },
  { id: "color.mango", kind: "color", colors: ["#FFE29A", "#FFA94D"] },
  { id: "color.greenApple", kind: "color", colors: ["#D9F99D", "#7BD389"] },
  { id: "color.silver", kind: "color", colors: ["#F2F2F5", "#C7C7CF"] },
  { id: "color.tangerine", kind: "color", colors: ["#FFB36B", "#F0612E"] },
  { id: "color.cherry", kind: "color", colors: ["#F2546B", "#9E1631"] },
  { id: "color.magenta", kind: "color", colors: ["#E64AC0", "#7A1D86"] },
  { id: "color.plum", kind: "color", colors: ["#8E4FB8", "#3B1859"] },
  { id: "color.deepSea", kind: "color", colors: ["#1E5BA8", "#0A1F4D"] },
  { id: "color.stone", kind: "color", colors: ["#8A8A8F", "#4A4A4F"] },
  { id: "color.carbon", kind: "color", colors: ["#3A3A3C", "#0E0E10"] },
  { id: "sky.clear", kind: "sky", colors: ["#5AA9F2", "#A8D4FA", "#E3F1FD"] },
  { id: "sky.sunrise", kind: "sky", colors: ["#F7B58A", "#F9D9B5", "#BFD8F2"] },
  { id: "sky.sunset", kind: "sky", colors: ["#3B4C8C", "#C46A7A", "#F5A35C"] },
  { id: "sky.dusk", kind: "sky", colors: ["#141B3D", "#3A3470", "#7A4F86"] },
  { id: "water.light", kind: "water", colors: ["#9EE2F0", "#3FB8D9", "#1A86B8"] },
  { id: "water.deepSea", kind: "water", colors: ["#0F4C75", "#082A47", "#03121F"] },
  { id: "aurora.green", kind: "aurora", colors: ["#030914", "#1FD89A", "#5B6CF2"] },
  { id: "aurora.purple", kind: "aurora", colors: ["#08051A", "#B04CF5", "#F25B9E"] },
  { id: "glitter.pink", kind: "glitter", colors: ["#3A0C2A", "#F06BB8", "#FFE3F3"] },
  { id: "glitter.gold", kind: "glitter", colors: ["#241A05", "#E8B64A", "#FFF4D6"] },
  { id: "glitter.silver", kind: "glitter", colors: ["#15171C", "#B8C0CC", "#FFFFFF"] },
];

const HEX = /^#[0-9A-Fa-f]{6}$/;

/** WCAG relative luminance of `#RRGGBB`. */
export function hexLuminance(hex: string): number {
  const v = parseInt(hex.slice(1), 16);
  const linear = (c: number) => {
    const x = c / 255;
    return x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * linear((v >> 16) & 255) + 0.7152 * linear((v >> 8) & 255) + 0.0722 * linear(v & 255);
}

export const colorsLuminance = (colors: string[]) => colors.reduce((n, c) => n + hexLuminance(c), 0) / colors.length;

/** Luminance as `kind` draws `colors`: gradients cover each stop evenly; Aurora and Glitter are mostly their base (first) color. */
export function kindLuminance(kind: BackgroundKind, colors: string[]): number {
  if ((kind === "aurora" || kind === "glitter") && colors.length > 1)
    return 0.85 * hexLuminance(colors[0]) + 0.15 * colorsLuminance(colors.slice(1));
  return colorsLuminance(colors);
}

/**
 * Validates a client `setBackground.background`. Returns the parts the server
 * keeps (id and setBy are assigned by the caller) or throws a message.
 * A photo needs `attachmentId` (checked by the caller against media) and `luminance`.
 */
export function parseBackground(raw: any): Omit<Background, "id" | "setBy" | "photo"> & { attachmentId?: string } {
  if (typeof raw !== "object" || raw === null) throw new Error("background");
  const kind = raw.kind;
  if (!BACKGROUND_KINDS.includes(kind)) throw new Error("background.kind");
  let colors: string[] | undefined;
  if (raw.colors !== undefined) {
    if (!Array.isArray(raw.colors) || raw.colors.length > 4 || raw.colors.some((c: unknown) => typeof c !== "string" || !HEX.test(c)))
      throw new Error("background.colors");
    colors = raw.colors.length ? raw.colors.map((c: string) => c.toUpperCase()) : undefined;
  }
  const look = raw.look;
  if (look !== undefined && (typeof look !== "string" || !look)) throw new Error("background.look");
  let luminance = raw.luminance;
  if (luminance !== undefined && (typeof luminance !== "number" || !(luminance >= 0 && luminance <= 1))) throw new Error("background.luminance");
  if (kind === "photo") {
    if (typeof raw.attachmentId !== "string" || !raw.attachmentId) throw new Error("background.attachmentId");
    if (luminance === undefined) throw new Error("background.luminance");
    return { kind, luminance, attachmentId: raw.attachmentId, ...(colors ? { colors } : {}) };
  }
  if (raw.attachmentId !== undefined) throw new Error("background.attachmentId");
  const preset = LOOKS.find((l) => l.id === look);
  if (!colors && preset && preset.kind === kind) colors = preset.colors;
  if (!colors) throw new Error("background.colors");
  if (luminance === undefined) luminance = kindLuminance(kind, colors);
  return { kind, colors, luminance, ...(look ? { look } : {}) };
}

/** A random preset for a bot. */
export function randomLook(rng: Rng) {
  return pick(rng, LOOKS);
}
