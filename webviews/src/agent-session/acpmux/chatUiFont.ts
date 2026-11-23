// The chat's interface font (`agentPane.display.font.ui`, Settings > Agent Chat > Interface Font): the
// face of the whole chat, its transcript, composer, cards and menus, not only the reply text the Chat
// Font preset sets. The default is the macOS system font (Lawrence, 2026-11-07: "default fonts on cmux
// for everything should be macos default, not inter, this applies to everything, including markdown
// viewer, chat trajectory etc"): desktop.css's `--font-ui` is already the system stack with no
// letter-spacing, so the default sets nothing. Each other choice sets `--font-ui` on the page and its
// own tracking on the type scale's letter-spacing tokens. Inter (cmux Inter, with the calculated
// tracking the app used through 2026-11-07, or stock), Roboto, IBM Plex Sans, Source Sans 3, Geist,
// Hanken Grotesk, Atkinson Hyperlegible Next and cmux Sans are bundled (chatFonts/FONTS.md) and load
// only when chosen; Verdana and the system font come with macOS. Leo, 2026-11-05: "I feel like we can
// look into a hell of a lot more and try out a hell of a lot more" (the font study,
// webviews/src/gallery/fontStudy, picked cmux Sans, Hanken Grotesk and Atkinson Hyperlegible Next).
// A font pack (a community typography theme) can name any family instead (`font.uiFamily`,
// chatDisplay.ts): it wins over the choice and draws as a bundled face does, at its designed spacing,
// its faces declared by chatFontFaces.ts.
import { measurableStack, quoteFamilyStack } from "./chatFontFaces";

export type ChatUiFont =
  | "inter-tuned"
  | "inter"
  | "verdana"
  | "roboto"
  | "plex"
  | "source-sans"
  | "geist"
  | "cmux-sans"
  | "hanken"
  | "atkinson"
  | "system-ui"
  | "system-ui-tight";

export const CHAT_UI_FONT_KEY = "agentPane.display.font.ui";
export const DEFAULT_CHAT_UI_FONT: ChatUiFont = "system-ui";
/// In the order the menus list them: the system font, the default, first.
export const CHAT_UI_FONTS: readonly ChatUiFont[] = [
  "system-ui",
  "system-ui-tight",
  "inter-tuned",
  "inter",
  "verdana",
  "roboto",
  "plex",
  "source-sans",
  "geist",
  "cmux-sans",
  "hanken",
  "atkinson",
];

export const isChatUiFont = (value: unknown): value is ChatUiFont =>
  typeof value === "string" && (CHAT_UI_FONTS as readonly string[]).includes(value);

/// The faces this module bundles, by the family name their @font-face declares (chatFonts/faces.ts).
export type BundledChatFont =
  | "inter-tuned"
  | "inter"
  | "roboto"
  | "plex"
  | "source-sans"
  | "geist"
  | "cmux-sans"
  | "hanken"
  | "atkinson";
export const BUNDLED_FAMILY: Record<BundledChatFont, string> = {
  "inter-tuned": "cmux Inter",
  inter: "cmux Inter",
  roboto: "cmux Roboto",
  plex: "cmux IBM Plex Sans",
  "source-sans": "cmux Source Sans 3",
  geist: "cmux Geist",
  "cmux-sans": "cmux Sans",
  hanken: "cmux Hanken Grotesk",
  atkinson: "cmux Atkinson Hyperlegible Next",
};
export const isBundledChatFont = (font: ChatUiFont): font is BundledChatFont => font in BUNDLED_FAMILY;
const isBundled = isBundledChatFont;

/// The system font's stack, desktop.css's `--font-ui`.
const SYSTEM = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
/// Each choice's stack: an installed copy of the font first where one may be, the system font for
/// what a bundled Latin subset lacks.
const STACKS: Record<ChatUiFont, string> = {
  "inter-tuned": `"${BUNDLED_FAMILY.inter}", Inter, ${SYSTEM}`,
  inter: `"${BUNDLED_FAMILY.inter}", Inter, ${SYSTEM}`,
  // Hacker News's and old Reddit's face. Linux has none: DejaVu Sans, Vera's heir, stands in there.
  verdana: 'Verdana, Geneva, "DejaVu Sans", sans-serif',
  roboto: `"${BUNDLED_FAMILY.roboto}", Roboto, ${SYSTEM}`,
  plex: `"${BUNDLED_FAMILY.plex}", "IBM Plex Sans", ${SYSTEM}`,
  "source-sans": `"${BUNDLED_FAMILY["source-sans"]}", "Source Sans 3", ${SYSTEM}`,
  geist: `"${BUNDLED_FAMILY.geist}", Geist, ${SYSTEM}`,
  "cmux-sans": `"${BUNDLED_FAMILY["cmux-sans"]}", ${SYSTEM}`,
  hanken: `"${BUNDLED_FAMILY.hanken}", "Hanken Grotesk", ${SYSTEM}`,
  atkinson: `"${BUNDLED_FAMILY.atkinson}", "Atkinson Hyperlegible Next", ${SYSTEM}`,
  "system-ui": SYSTEM,
  "system-ui-tight": SYSTEM,
};

/// The type scale's steps whose letter-spacing token each choice sets (pages/shared/desktop.css).
const STEPS = ["caption", "detail", "body", "field", "title", "heading"] as const;
/// System UI, tight: a step under the system font's own spacing, more at the larger steps, as
/// Apple's display sizes tighten.
const TIGHT: Record<(typeof STEPS)[number], string> = {
  caption: "0em",
  detail: "-0.004em",
  body: "-0.008em",
  field: "-0.01em",
  title: "-0.014em",
  heading: "-0.02em",
};

/// cmux Inter: Inter's dynamic tracking, -0.0223 + 0.185 * e^(-0.1745 * size) em at each step's size
/// (rsms's Inter metrics), the app's UI tracking through 2026-11-07.
const INTER_TUNED: Record<(typeof STEPS)[number], string> = {
  caption: "0.0048em",
  detail: "0.0005em",
  body: "-0.0032em",
  field: "-0.0062em",
  title: "-0.0088em",
  heading: "-0.0167em",
};

/// cmux Sans: Source Sans 3's narrow letters under a taller lowercase read packed at chat sizes, so
/// it draws a step looser than its designed spacing, most at the small steps (Leo, 2026-11-19: "The
/// kerning in cmux sans is off it all looks too packed together and narrow a lot of the time").
const CMUX_SANS: Record<(typeof STEPS)[number], string> = {
  caption: "0.02em",
  detail: "0.018em",
  body: "0.015em",
  field: "0.012em",
  title: "0.008em",
  heading: "0.004em",
};

/// The letter-spacing table `font` sets on the type scale's steps, or null when it sets none.
const TRACKING: Partial<Record<ChatUiFont, Record<(typeof STEPS)[number], string>>> = {
  "system-ui-tight": TIGHT,
  "inter-tuned": INTER_TUNED,
  "cmux-sans": CMUX_SANS,
};
const trackingTable = (font: ChatUiFont) => TRACKING[font] ?? null;

/// The letter-spacing `font` gives a type-scale step, in em: what chatUiFontVariables sets on
/// `--text-STEP--letter-spacing`, 0 for a step it has none for and for the faces with none.
export function chatUiTracking(font: ChatUiFont, step: string): number {
  const table = trackingTable(font);
  return table && step in table ? Number.parseFloat(table[step as (typeof STEPS)[number]]) : 0;
}

/// The page's variables for `font`; a null value removes the variable (the stylesheet's own: the
/// system font with no letter-spacing). `--cv-tracking` is the reply text's spacing (conversation.css).
/// A pack's `family` (a safe family or stack, chatDisplay.ts) wins over `font`: its stack, then the
/// system font, at its designed spacing.
export function chatUiFontVariables(font: ChatUiFont, family: string | null = null): Record<string, string | null> {
  const variables: Record<string, string | null> = { "--font-ui": null, "--cv-tracking": null };
  for (const step of STEPS) variables[`--text-${step}--letter-spacing`] = null;
  if (family) {
    variables["--font-ui"] = `${quoteFamilyStack(family)}, ${SYSTEM}`;
    variables["--cv-tracking"] = "0px";
    for (const step of STEPS) variables[`--text-${step}--letter-spacing`] = "0em";
    return variables;
  }
  if (font === DEFAULT_CHAT_UI_FONT) return variables;
  variables["--font-ui"] = STACKS[font];
  const table = trackingTable(font);
  // The reply text follows the body step of the tables that loosen or tighten the face (not cmux
  // Inter's, whose reply text kept its own spacing).
  variables["--cv-tracking"] = font === "system-ui-tight" ? TIGHT.body : font === "cmux-sans" ? CMUX_SANS.body : "0px";
  for (const step of STEPS) variables[`--text-${step}--letter-spacing`] = table ? table[step] : "0em";
  return variables;
}

/// The bundled faces this document has finished loading (loadChatUiFont).
const loadedFaces = new Set<BundledChatFont>();

/// What the row estimator's canvas measures the chat's text as when it follows the interface font
/// (a canvas can't read CSS variables). A bundled face counts only once it has loaded: until then
/// the page draws the stack's next face, so the estimate measures that, and the stack changing at
/// the load is what makes the estimator's caches, keyed by it, measure the text again.
export function chatUiMeasureStack(font: ChatUiFont, family: string | null = null): string {
  if (family) {
    // A pack's family counts once its face has loaded (chatFontFaces.ts measurableStack).
    const stack = measurableStack(family);
    return stack ? `${stack}, ${SYSTEM}` : SYSTEM;
  }
  if (isBundled(font) && !loadedFaces.has(font)) return STACKS[font].replace(`"${BUNDLED_FAMILY[font]}", `, "");
  return STACKS[font];
}

/// Declares `font`'s bundled face in this document, once, the first time it is chosen: a chat
/// that keeps the default never loads one. `loaded` runs once the face is ready to measure.
export function loadChatUiFont(font: ChatUiFont, loaded: () => void = () => {}): void {
  if (!isBundled(font) || loadedFaces.has(font) || typeof document === "undefined") return;
  void import("./chatFonts/faces")
    .then((faces) => faces.installChatFontFace(font))
    .then(() => {
      loadedFaces.add(font);
      loaded();
    });
}
