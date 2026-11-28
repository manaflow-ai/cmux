// l10n-allow-file: gallery fixtures, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Inspect the last agent request", 10),
  assistant("The request completed successfully.", 9),
  summary(9, { status: "completed" }),
]);

export default agentPaneEntry({
  id: "agent-pane.inspector",
  title: "ACP inspector",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/Inspector.tsx#Inspector"],
  variants: {
    "chat-menu": {
      snapshot,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menuitem"]'));
      },
    },
    "wire-log": {
      snapshot,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.click({ role: "menuitem", name: "ACP inspector" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-inspector"));
      },
    },
  },
});
