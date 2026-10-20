// l10n-allow-file: gallery fixture data and descriptions, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const snapshot = chat([user("Check the project", 2), assistant("The project is ready.", 1)]);
const native = { "folder.openIn": { apps: [{ id: "editor", name: "Editor" }] } };

const open: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-button"));
  ctx.document.defaultView!.cmuxAcpmuxBridge!.applyCustomization({ layout: { threadTitle: true } });
  if (ctx.find({ selector: ".acpmux-summary-button" }).getAttribute("aria-pressed") !== "true")
    await ctx.click({ selector: ".acpmux-summary-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card__close"));
};

const closed: Play = async (ctx) => {
  await open(ctx);
  await ctx.click({ selector: ".acpmux-summary-card__close" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-summary-card:not([aria-hidden])"));
  if (ctx.document.activeElement !== ctx.find({ selector: ".acpmux-summary-button" }))
    throw new Error("Closing Thread details must focus its header button");
};

export default agentPaneEntry({
  id: "agent-pane.thread-details-panel",
  title: "Thread details panel",
  area: "Agent pane",
  height: 600,
  widths: { narrow: 900, normal: 1400, wide: 1600 },
  covers: [
    "agent-session/acpmux/summary/SummaryCard.tsx#SummaryCard",
    "agent-session/acpmux/summary/ThreadDetails.tsx#ThreadDetails",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
  ],
  variants: {
    open: { snapshot, native, play: open },
    closed: { snapshot, native, play: closed },
  },
});
