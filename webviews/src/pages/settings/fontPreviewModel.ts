// What a font row's preview draws (FontPreview.tsx). Leo, 2026-11-19: "idk i dont have pictures to
// see or sliders to adjust for the font". A face choice (the chat's Interface Font and Chat Font, the
// Markdown viewer's Font) draws a picture of every choice in its own face, at the size and line height
// its surface's sliders set, so moving a slider resizes every picture at once. A font family row (the
// terminal's, the editor's) draws one sample of the picked family at its size. The stacks are the ones
// the surfaces draw with (chatUiFont.ts, chatDisplay.ts, pages/markdown/settings.ts).
import {
  CHAT_UI_FONT_KEY,
  chatUiFontVariables,
  isBundledChatFont,
  isChatUiFont,
} from "../../agent-session/acpmux/chatUiFont";
import { fontFace, uiFontFace } from "./fontPickerModel";
import { MARKDOWN_FONT_PRESETS, type MarkdownFontPreset } from "../markdown/settings";

const SYSTEM = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
const MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

/** What the preview reads besides the row's own value: other keys' values. */
export type Values = (key: string) => unknown;

export type ChoicePreview = {
  kind: "choices";
  /** The surface's size and line height keys, whose sliders resize the pictures. */
  size: string;
  lineHeight: string | null;
  /** The stack a choice draws in, and its letter-spacing (CSS), given the other keys. */
  face(choice: string, values: Values): { family: string; tracking: string };
  /** Loads a bundled face before it draws; resolves at once for a face the Mac has. */
  load?(choice: string): Promise<void>;
};

export type FamilyPreview = {
  kind: "family";
  size: string;
  /** The family when the row is unset: another key's (the editor follows the terminal), else none. */
  fallback: string | null;
  /** What the sample draws: code (a fixed-pitch family) or interface text (the App Font). */
  specimen?: "code" | "text";
};

export type FontPreview = ChoicePreview | FamilyPreview;

/** The keys a surface's code font resolves through, in order: the chat's own, else the Markdown
 * viewer's, else the terminal's family, which is what `--cmux-diff-code-font-family` carries
 * (chatDisplay.ts: "Code follows the terminal font ... unless a code font is set"). The first one set
 * wins; with none set, code draws in the default mono stack. A family the host supplies but no key
 * holds (Ghostty's own configured font, appearance.ts) is not among them, so an unset terminal family
 * still previews as the default stack. */
const CHAT_CODE_KEYS = ["agentPane.display.code.family", "markdown.code.family", "terminal.fontFamily"] as const;
const MARKDOWN_CODE_KEYS = ["markdown.code.family", "terminal.fontFamily"] as const;

/** Every key a picture reads besides its own row's: what FontPreview.tsx subscribes to, so moving any
 * of them redraws the tiles that follow it. `MARKDOWN_CODE_KEYS` is a tail of `CHAT_CODE_KEYS`, so
 * these are all of them. */
export const PREVIEW_INPUTS = ["markdown.font.preset", CHAT_UI_FONT_KEY, ...CHAT_CODE_KEYS] as const;

/** What `var(--cmux-md-code-font-family)` and a mono choice draw in, given the other keys. */
function codeStack(values: Values, keys: readonly string[]): string {
  for (const key of keys) {
    const value = values(key);
    if (typeof value === "string" && value.trim() !== "") return fontFace(value.trim());
  }
  return MONO;
}

/** What `var(--font-ui)` resolves to in the chat: the Interface Font's own stack. So a Chat Font
 * choice that follows the interface face (System, and a Markdown viewer left on its system preset)
 * draws in cmux Sans when that is the Interface Font, as the chat itself does (chatUiFont.ts). */
function chatUiStack(values: Values): string {
  const choice = values(CHAT_UI_FONT_KEY);
  if (!isChatUiFont(choice)) return SYSTEM;
  return chatUiFontVariables(choice)["--font-ui"] ?? SYSTEM;
}

/** A Markdown preset's stack, with the page's variables resolved to what the Settings page has: `ui`
 * for the face the body inherits, `code` for the one its code draws in. */
function markdownStack(preset: unknown, ui: string, code: string): string {
  const stack =
    MARKDOWN_FONT_PRESETS[
      (preset as MarkdownFontPreset) in MARKDOWN_FONT_PRESETS ? (preset as MarkdownFontPreset) : "system"
    ];
  return stack.replace("var(--font-ui)", ui).replace("var(--cmux-md-code-font-family)", code);
}

const chatPreset = (choice: string, values: Values): string => {
  const ui = chatUiStack(values);
  return choice === "markdown"
    ? markdownStack(values("markdown.font.preset"), ui, codeStack(values, MARKDOWN_CODE_KEYS))
    : choice === "serif"
      ? '"New York", ui-serif, "Iowan Old Style", Georgia, serif'
      : choice === "mono"
        ? codeStack(values, CHAT_CODE_KEYS)
        : ui;
};

export const FONT_PREVIEWS: Readonly<Record<string, FontPreview>> = {
  "agentPane.display.font.ui": {
    kind: "choices",
    size: "agentPane.display.font.size",
    lineHeight: "agentPane.display.font.lineHeight",
    face(choice) {
      if (!isChatUiFont(choice)) return { family: SYSTEM, tracking: "0" };
      const variables = chatUiFontVariables(choice);
      return { family: variables["--font-ui"] ?? SYSTEM, tracking: variables["--text-body--letter-spacing"] ?? "0" };
    },
    async load(choice) {
      if (!isChatUiFont(choice) || !isBundledChatFont(choice)) return;
      const { installChatFontFace } = await import("../../agent-session/acpmux/chatFonts/faces");
      await installChatFontFace(choice);
    },
  },
  "agentPane.display.font.preset": {
    kind: "choices",
    size: "agentPane.display.font.size",
    lineHeight: "agentPane.display.font.lineHeight",
    face: (choice, values) => ({ family: chatPreset(choice, values), tracking: "0" }),
  },
  "markdown.font.preset": {
    kind: "choices",
    size: "markdown.font.size",
    lineHeight: "markdown.font.lineHeight",
    // The viewer is its own page: its body inherits that page's `--font-ui`, the system face, not the
    // chat's Interface Font.
    face: (choice, values) => ({
      family: markdownStack(choice, SYSTEM, codeStack(values, MARKDOWN_CODE_KEYS)),
      tracking: "0",
    }),
  },
  "terminal.fontFamily": { kind: "family", size: "terminal.fontSize", fallback: null },
  // The App Font (Leo, 2026-11-08: "i wanna just be able to see different fonts just like how i can
  // see different themes as preview"): a line of interface text in the picked family at the Text Size.
  "appearance.appFont": {
    kind: "family",
    size: "appearance.metrics.chromeFontSize",
    fallback: null,
    specimen: "text",
  },
  "editor.fontFamily": { kind: "family", size: "editor.fontSize", fallback: "terminal.fontFamily" },
};

/** The specimens: letters every Latin face draws distinctly, and the characters code fonts are chosen
 * by. Not words, so they need no translation. */
export const TEXT_SPECIMEN = "Aa Gg Rr 0123";
export const CODE_SPECIMEN = "0O 1lI {} => != ~ <>";

/** Interface text for the App Font's sample: glyphs, then a line of the kind of text cmux shows. */
export const UI_SPECIMEN = "Aa Gg Rr 0123 · Settings, Chat, Sidebar";

/** A family row's stack: the picked family (the font picker's own quoting), else the system monospace;
 * for interface text, the family over the system face, else the system face. */
export const familyStack = (name: string | null, specimen: "code" | "text" = "code"): string =>
  specimen === "text" ? (name ? uiFontFace(name) : SYSTEM) : name ? fontFace(name) : MONO;

/** A number setting's value, else its range's placeholder, clamped to the range. */
export function numberOr(
  value: unknown,
  range: { min: number; max: number; placeholder?: number } | undefined,
  fallback: number,
): number {
  const raw = typeof value === "number" && Number.isFinite(value) ? value : (range?.placeholder ?? fallback);
  return range ? Math.min(range.max, Math.max(range.min, raw)) : raw;
}
