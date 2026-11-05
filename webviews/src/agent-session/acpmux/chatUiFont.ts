// The chat's interface font (`agentPane.display.font.ui`, Settings > Agent Chat > Interface Font): the
// face of the whole chat, its transcript, composer, cards and menus, not only the reply text the Chat
// Font preset sets. Leo, 2026-11-05: "right now it's just Apple System, right? But, like, I feel like
// we can look into a hell of a lot more and try out a hell of a lot more. Actually, I haven't tried
// switching fonts in my own app yet." The default is today's: Inter with its calculated tracking
// (#24100), the face the Linux gallery captures share with the app. On a Mac too that is the
// bundled InterVariable every cmux web view declares at document start (BundledFonts.pageScript),
// not SF, so the default sets nothing and renders as today; System UI is the system font (SF). Each other choice sets
// `--font-ui` on the page and its own tracking on the type scale's letter-spacing tokens (Inter's
// curve is tuned to Inter, so the others draw at their designed spacing, and System UI, tight a
// step under it). Roboto, IBM Plex Sans, Source Sans 3 and Geist are bundled (chatFonts/FONTS.md)
// and load only when chosen; Verdana and the system font come with macOS.

export type ChatUiFont =
  | "inter-tuned"
  | "inter"
  | "verdana"
  | "roboto"
  | "plex"
  | "source-sans"
  | "geist"
  | "system-ui"
  | "system-ui-tight";

export const CHAT_UI_FONT_KEY = "agentPane.display.font.ui";
export const DEFAULT_CHAT_UI_FONT: ChatUiFont = "inter-tuned";
/// In the order the menus list them.
export const CHAT_UI_FONTS: readonly ChatUiFont[] = [
  "inter-tuned",
  "inter",
  "verdana",
  "roboto",
  "plex",
  "source-sans",
  "geist",
  "system-ui",
  "system-ui-tight",
];

export const isChatUiFont = (value: unknown): value is ChatUiFont =>
  typeof value === "string" && (CHAT_UI_FONTS as readonly string[]).includes(value);

/// The faces this module bundles, by the family name their @font-face declares (chatFonts/faces.ts).
export type BundledChatFont = "roboto" | "plex" | "source-sans" | "geist";
export const BUNDLED_FAMILY: Record<BundledChatFont, string> = {
  roboto: "cmux Roboto",
  plex: "cmux IBM Plex Sans",
  "source-sans": "cmux Source Sans 3",
  geist: "cmux Geist",
};
const isBundled = (font: ChatUiFont): font is BundledChatFont => font in BUNDLED_FAMILY;

/// Each choice's stack: an installed copy of the font first where one may be, Inter for what a
/// bundled Latin subset lacks.
const STACKS: Record<Exclude<ChatUiFont, "inter-tuned">, string> = {
  inter: '"Inter", system-ui, sans-serif',
  // Hacker News's and old Reddit's face. Linux has none: DejaVu Sans, Vera's heir, stands in there.
  verdana: 'Verdana, Geneva, "DejaVu Sans", sans-serif',
  roboto: `"${BUNDLED_FAMILY.roboto}", Roboto, "Inter", sans-serif`,
  plex: `"${BUNDLED_FAMILY.plex}", "IBM Plex Sans", "Inter", sans-serif`,
  "source-sans": `"${BUNDLED_FAMILY["source-sans"]}", "Source Sans 3", "Inter", sans-serif`,
  geist: `"${BUNDLED_FAMILY.geist}", Geist, "Inter", sans-serif`,
  "system-ui": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
  "system-ui-tight": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
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

/// The page's variables for `font`; a null value removes the variable (the stylesheet's own,
/// today's look). `--cv-tracking` is the reply text's spacing (conversation.css).
export function chatUiFontVariables(font: ChatUiFont): Record<string, string | null> {
  const variables: Record<string, string | null> = { "--font-ui": null, "--cv-tracking": null };
  for (const step of STEPS) variables[`--text-${step}--letter-spacing`] = null;
  if (font === "inter-tuned") return variables;
  variables["--font-ui"] = STACKS[font];
  const tight = font === "system-ui-tight";
  variables["--cv-tracking"] = tight ? TIGHT.body : "0px";
  for (const step of STEPS) variables[`--text-${step}--letter-spacing`] = tight ? TIGHT[step] : "0em";
  return variables;
}

/// What the row estimator's canvas measures the chat's text as when it follows the interface font
/// (a canvas can't read CSS variables).
export function chatUiMeasureStack(font: ChatUiFont): string {
  return font === "inter-tuned" ? '"Inter", system-ui, sans-serif' : STACKS[font];
}

/// Declares `font`'s bundled face in this document, once, the first time it is chosen: a chat
/// that keeps the default never loads one.
export function loadChatUiFont(font: ChatUiFont): void {
  if (!isBundled(font) || typeof document === "undefined") return;
  void import("./chatFonts/faces").then((faces) => faces.installChatFontFace(font));
}
