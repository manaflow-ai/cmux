// What a font row's preview draws (FontPreview.tsx). Leo, 2026-11-19: "idk i dont have pictures to
// see or sliders to adjust for the font". A face choice (the chat's Interface Font and Chat Font, the
// Markdown viewer's Font) draws a picture of every choice in its own face, at the size and line height
// its surface's sliders set, so moving a slider resizes every picture at once. A font family row (the
// terminal's, the editor's) draws one sample of the picked family at its size. The stacks are the ones
// the surfaces draw with (chatUiFont.ts, chatDisplay.ts, pages/markdown/settings.ts).
import { chatUiFontVariables, isChatUiFont, isBundledChatFont } from "../../agent-session/acpmux/chatUiFont";
import { fontFace } from "./fontPickerModel";
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
};

export type FontPreview = ChoicePreview | FamilyPreview;

/** A Markdown preset's stack, with the page's variables resolved to what the Settings page has. */
function markdownStack(preset: unknown): string {
  const stack =
    MARKDOWN_FONT_PRESETS[
      (preset as MarkdownFontPreset) in MARKDOWN_FONT_PRESETS ? (preset as MarkdownFontPreset) : "system"
    ];
  return stack.replace("var(--font-ui)", SYSTEM).replace("var(--cmux-md-code-font-family)", MONO);
}

const chatPreset = (choice: string, values: Values): string =>
  choice === "markdown"
    ? markdownStack(values("markdown.font.preset"))
    : choice === "serif"
      ? '"New York", ui-serif, "Iowan Old Style", Georgia, serif'
      : choice === "mono"
        ? MONO
        : SYSTEM;

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
    face: (choice) => ({ family: markdownStack(choice), tracking: "0" }),
  },
  "terminal.fontFamily": { kind: "family", size: "terminal.fontSize", fallback: null },
  "editor.fontFamily": { kind: "family", size: "editor.fontSize", fallback: "terminal.fontFamily" },
};

/** The specimens: letters every Latin face draws distinctly, and the characters code fonts are chosen
 * by. Not words, so they need no translation. */
export const TEXT_SPECIMEN = "Aa Gg Rr 0123";
export const CODE_SPECIMEN = "0O 1lI {} => != ~ <>";

/** A family row's stack: the picked family (the font picker's own quoting), else the system monospace. */
export const familyStack = (name: string | null): string => (name ? fontFace(name) : MONO);

/** A number setting's value, else its range's placeholder, clamped to the range. */
export function numberOr(
  value: unknown,
  range: { min: number; max: number; placeholder?: number } | undefined,
  fallback: number,
): number {
  const raw = typeof value === "number" && Number.isFinite(value) ? value : (range?.placeholder ?? fallback);
  return range ? Math.min(range.max, Math.max(range.min, raw)) : raw;
}
