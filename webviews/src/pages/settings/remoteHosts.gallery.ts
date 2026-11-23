// l10n-allow-file: gallery fixtures, not shipped UI.
import { settingsPageEntry } from "../../gallery/format";

export default settingsPageEntry({
  id: "pages.settings-remote-hosts",
  title: "Settings Remote Workspaces",
  area: "Settings",
  height: 720,
  covers: ["pages/settings/components/RemoteHostsExperiment.tsx"],
  variants: {
    off: {
      section: "devices",
      play: async (ctx) => {
        await ctx.scroll({ selector: "main.content" }, "bottom");
        if (ctx.document.querySelector("[data-remote-hosts-connect]"))
          throw new Error("Preview is visible while disabled");
      },
      note: "Default: the remote-workspace experiment is absent and no host connection starts.",
    },
    enabled: {
      section: "devices",
      options: { values: { "labs.previewFeatures": true } },
      play: async (ctx) => {
        await ctx.scroll({ selector: "main.content" }, "bottom");
        await ctx.waitFor(() => ctx.document.querySelector("[data-remote-hosts-connect]"));
      },
      note: "Labs preview enabled: one standard Settings row opens the existing native host picker.",
    },
    refused: {
      section: "devices",
      options: { values: { "labs.previewFeatures": true }, actionRan: false },
      play: async (ctx) => {
        await ctx.scroll({ selector: "main.content" }, "bottom");
        await ctx.click({ selector: "[data-remote-hosts-connect]" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-devices-group="remote-hosts"] [role="alert"]'));
      },
      note: "A refused picker shows an error in the row and the button remains available for retry.",
    },
  },
});
