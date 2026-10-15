// The Fonts group's live preview (appearance.fonts.*): a short chat exchange in the text face at the
// chat size, and a code block in the code face, redrawn as the rows above change. The faces are
// the stacks the app sends pages (AppFonts.swift `cssVariables`), so the preview shows what a chat
// will look like without leaving Settings.
import type { CSSProperties } from "react";
import { hostCodeFontFamily } from "../../../appearance";
import { useSettingsState } from "../context";
import { valueOf } from "../store";
import { t } from "../strings";

export const FONTS_GROUP = "settings.group.fonts";
const UI_KEY = "appearance.fonts.ui";
const CODE_KEY = "appearance.fonts.code";
const CHAT_SIZE_KEY = "appearance.fonts.chatSize";

/** The page's own stack for the system face, and the design faces (AppFonts.Design.css). */
const SYSTEM = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';
const UI_STACKS: Record<string, string> = {
  system: SYSTEM,
  rounded: "ui-rounded, -apple-system, system-ui, sans-serif",
  serif: 'ui-serif, "New York", Georgia, serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
};
const MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

/** The preview's faces and size for the current values; an unset code face is the terminal's
 * (the family the host sends, `hostCodeFontFamily`), else the chat's own. */
function previewFonts(ui: unknown, code: unknown, size: unknown): { ui: string; code: string; size: number } {
  const family = typeof code === "string" && code.trim() !== "" ? code.trim() : hostCodeFontFamily();
  const points = typeof size === "number" && Number.isFinite(size) ? size : 14;
  return {
    ui: UI_STACKS[typeof ui === "string" ? ui : "system"] ?? SYSTEM,
    code: family ? `${JSON.stringify(family)}, ${MONO}` : `var(--cmux-font-code, ${MONO})`,
    size: points,
  };
}

export function FontPreview() {
  const state = useSettingsState();
  const fonts = previewFonts(valueOf(state, UI_KEY), valueOf(state, CODE_KEY), valueOf(state, CHAT_SIZE_KEY));
  const style = {
    "--font-preview-ui": fonts.ui,
    "--font-preview-code": fonts.code,
    "--font-preview-size": `${fonts.size}px`,
  } as CSSProperties;
  return (
    <figure className="font-preview" data-font-preview="" style={style} aria-label={t("settingsPage.fonts.preview")}>
      <p className="font-preview-user">{t("settingsPage.fonts.sampleQuestion")}</p>
      <p className="font-preview-reply">{t("settingsPage.fonts.sampleReply")}</p>
      <pre className="font-preview-code">
        <code>{"export function retry(attempts = 3) {\n  return attempts > 0 ? run() : fail(); // 0Oo 1lI\n}"}</code>
      </pre>
    </figure>
  );
}
