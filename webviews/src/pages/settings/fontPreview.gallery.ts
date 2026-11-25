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
    // The App Font (Leo, 2026-11-08: "i wanna just be able to see different fonts just like how i can
    // see different themes as preview"): the row unset, a proportional family picked, and the picker
    // open over every installed family, each in its own face.
    "app-font-system": variant(
      "appearance",
      "appearance.appFont",
      { "appearance.metrics.chromeFontSize": 15 },
      "The App Font row unset: System on its button, the sample's interface text in the system face at the 15 px Text Size.",
      15,
    ),
    "app-font-avenir": variant(
      "appearance",
      "appearance.appFont",
      { "appearance.appFont": "Avenir Next", "appearance.metrics.chromeFontSize": 15 },
      "Avenir Next picked: the button and the sample draw in it; every page of the app follows (WebTheme).",
      15,
    ),
    "app-font-picker-open": {
      ...variant(
        "appearance",
        "appearance.appFont",
        { "appearance.appFont": "Georgia", "appearance.metrics.chromeFontSize": 15 },
        "The App Font picker open: System first, then every installed family, proportional ones too, each in its own face; Georgia checked. A highlighted row previews in the whole app.",
        15,
      ),
      play: async (ctx) => {
        const row = () => ctx.document.querySelector<HTMLElement>('[data-row-key="appearance.appFont"]');
        await ctx.waitFor(() => row()?.querySelector<HTMLElement>(".font-sample")?.dataset.size === "15");
        row()!.querySelector<HTMLElement>("[data-font-picker]")!.click();
        await ctx.waitFor(() => ctx.document.querySelector('[data-font-option="Avenir Next"]') !== null);
        await ctx.document.fonts.ready;
      },
    },
    "terminal-family": variant(
      "terminal",
      "terminal.fontFamily",
      { "terminal.fontFamily": "Menlo", "terminal.fontSize": 17 },
      "The terminal font row's sample: Menlo at the size slider's 17 px.",
      17,
    ),
  },
});
