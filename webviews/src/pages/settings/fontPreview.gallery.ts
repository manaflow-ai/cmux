// l10n-allow-file: gallery fixtures, not shipped UI.
// Font rows' pictures (components/FontPreview.tsx). Leo, 2026-11-19: "idk i dont have pictures to see
// or sliders to adjust for the font". Each variant opens the row and waits for its pictures to draw
// at the size the fixture sets, so a capture shows the faces, not the fallback.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import { sectionShowing } from "./categories";

const variant = (
  section: string,
  focus: string,
  values: Record<string, unknown>,
  note: string,
  size: number,
): SettingsPageVariant => ({
  // Refused at once when `section` does not open the page `focus`'s row is on, rather than captured
  // as the wrong page with a `play` that waits forever (categories.ts sectionShowing).
  section: sectionShowing(section, focus),
  focus,
  options: { values },
  note,
  play: async (ctx) => {
    await ctx.waitFor(() => {
      const row = ctx.document.querySelector<HTMLElement>(`[data-row-key="${focus}"]`);
      const drawn = row?.querySelector<HTMLElement>(".font-tile-picture, .font-sample");
      return drawn?.dataset.size === String(size);
    });
    await ctx.document.fonts.ready;
  },
});

export default settingsPageEntry({
  id: "pages.settings-font-preview",
  title: "Settings font pictures and size sliders",
  area: "Settings",
  height: 900,
  widths: { narrow: 520, normal: 860 },
  covers: ["page:cmux.settings", "pages/settings/components/FontPreview.tsx"],
  variants: {
    "chat-default": variant(
      "chat",
      "agentPane.display.font.ui",
      {},
      "Chat Text: a tile per Interface Font in its own face at the chat's 14 px, System marked In Use.",
      14,
    ),
    "chat-cmux-sans-large": variant(
      "chat",
      "agentPane.display.font.ui",
      {
        "agentPane.display.font.ui": "cmux-sans",
        "agentPane.display.font.size": 20,
        "agentPane.display.font.lineHeight": 1.4,
      },
      "cmux Sans picked, the size slider at 20 and line height 1.4: every tile draws at that size.",
      20,
    ),
    "markdown-serif": variant(
      "editor",
      "markdown.font.preset",
      { "markdown.font.preset": "serif", "markdown.font.size": 18 },
      "The Markdown viewer's Font: System, Serif and Code tiles at 18 px, Serif in use.",
      18,
    ),
    "terminal-family": variant(
      "terminal",
      "terminal.fontFamily",
      { "terminal.fontFamily": "Menlo", "terminal.fontSize": 17 },
      "The terminal font row's sample: Menlo at the size slider's 17 px.",
      17,
    ),
  },
});
