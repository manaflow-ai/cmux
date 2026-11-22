// l10n-allow-file: isolated gallery prototype, not shipped UI.
// Placement (b): Settings › Agents (AI, always in the sidebar) leads with the history card, so the
// import is neither Chief-only nor behind More › Import. The page is the real Settings page on its
// mock provider; the play puts the existing Import card (importSuggestions) at the top of Agents for
// this stage only (the layout schema is unchanged), then opens Agents.
import { settingsPageEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { HISTORY_CARD } from "./fixtures";

async function openAgentsWithCard(ctx: PlayContext) {
  const { categoryById } = await import("../../pages/settings/categories");
  const lead = categoryById("agents").lead as string[];
  if (!lead.includes("importSuggestions")) lead.unshift("importSuggestions");
  await ctx.click({ selector: '[data-section-link="agents"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-section="agents"] [data-import-card="agents.history"]'));
}

export default settingsPageEntry({
  id: "prototype.import-history-settings",
  title: "Bring your history: Settings › Agents card",
  area: "Prototypes",
  experimental: true,
  covers: ["prototypes/import-history/SettingsAgentsCard.gallery.ts"],
  keywords: ["import", "history", "memory", "claude code", "codex", "settings", "agents"],
  variants: {
    "agents-card": {
      note: "(b) First card in Settings › Agents: every agent's memory, not the Chief's alone.",
      section: "general",
      host: { import_suggestions: { title: "", cards: [HISTORY_CARD] } },
      play: openAgentsWithCard,
    },
  },
});
