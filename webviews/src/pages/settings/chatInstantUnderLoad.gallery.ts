// l10n-allow-file: gallery fixtures, not shipped UI.
import { chatInstantUnderLoad } from "../../agent-session/acpmux/newtab/chatInstantUnderLoad.experiment";
import { experimentArm } from "../../experiments/experiment";
import { settingsPageEntry } from "../../gallery/format";

const key = "experiments.chat_instant_under_load";
const row = { section: "experimental", focus: key };
const selector = `[data-row-key="${key}"] [role="switch"]`;

export default settingsPageEntry({
  id: "pages.chat-instant-under-load",
  title: "Prioritize Chat Input",
  area: "Settings",
  height: 620,
  covers: ["page:cmux.settings", "agent-session/acpmux/newtab/chatStore.ts"],
  experiment: {
    definition: chatInstantUnderLoad,
    script: [
      {
        name: "Select the scheduling arm",
        run: async (ctx) => {
          const on = experimentArm(chatInstantUnderLoad) === "on";
          await ctx.waitFor(() => ctx.document.querySelector(selector));
          const control = ctx.document.querySelector<HTMLButtonElement>(selector)!;
          if ((control.getAttribute("aria-checked") === "true") !== on) control.click();
          await ctx.waitFor(() => ctx.document.querySelector(selector)?.getAttribute("aria-checked") === String(on));
        },
      },
    ],
  },
  variants: {
    default: { ...row, note: "The setting is absent. Chat list publication uses its usual timing." },
    enabled: { ...row, options: { values: { [key]: true } }, note: "A warm list waits for an idle slice." },
    disabled: {
      ...row,
      options: { values: { [key]: true } },
      steps: [
        { selector, action: "click" },
        { selector: selector + '[aria-checked="false"]', action: "wait" },
      ],
      note: "Turning the experiment off restores the usual timing.",
    },
  },
});
