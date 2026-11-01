// l10n-allow-file: sample transcript for the pane-edge scrollbar regression.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat(
  Array.from({ length: 40 }, (_, index) => [
    user(`Check part ${index + 1} of the plan`, 80 - index * 2),
    assistant(`Part ${index + 1} is checked. The retry helper and its tests pass.`, 79 - index * 2),
  ]).flat(),
);
const native = { "pane.tabState": { inspector: true } };

export default agentPaneEntry({
  id: "agent-pane.scrollbar-edge",
  title: "Transcript scrollbar at the pane edge",
  area: "Agent pane",
  height: 700,
  covers: ["agent-session/acpmux/session-info/sessionInfo.css"],
  variants: {
    open: {
      note: "Session Info may move the text column left; the scrollbar stays at the pane's right edge.",
      snapshot,
      native,
    },
    closed: {
      note: "Closing Session Info keeps the same pane-edge scrollbar and aligned transcript/composer column.",
      snapshot,
      native,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Session Info" });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-session-info"));
      },
    },
  },
});
