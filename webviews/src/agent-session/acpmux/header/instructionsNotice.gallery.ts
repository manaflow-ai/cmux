// l10n-allow-file: gallery fixtures, not shipped UI.
// The chat menu's Edit CLAUDE.md when the app can't open the file: a notice above the composer
// says why, with Retry and Dismiss, instead of nothing happening.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const snapshot = chat([
  user("Tighten the retry helper", 10),
  assistant("Done: the helper retries three times.", 9),
  summary(9, { status: "completed" }),
]);

type Log = { method: string; params?: unknown }[];
const asked = (ctx: { document: Document }) =>
  (ctx.document.defaultView as unknown as { cmuxGalleryLog: Log }).cmuxGalleryLog.filter(
    ({ method }) => method === "project.instructions",
  ).length;

export default agentPaneEntry({
  id: "agent-pane.instructions-notice",
  title: "Project instructions: open failed",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/header/InstructionsNotice.tsx#InstructionsNotice"],
  variants: {
    "outside-folder": {
      note: "Play: Edit CLAUDE.md when CLAUDE.md links out of the chat folder: a notice says so, Retry asks again, Dismiss clears it.",
      snapshot,
      native: { "project.instructions": { nativeError: { code: "transport.path_outside_roots" } } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.click({ role: "menuitem", name: "Edit CLAUDE.md" });
        await ctx.waitFor(() =>
          ctx.document.querySelector('[role="alert"]')?.textContent?.includes("links outside the chat folder"),
        );
        await ctx.click({ role: "button", name: "Retry" });
        await ctx.waitFor(() => asked(ctx) === 2);
        await ctx.click({ role: "button", name: "Dismiss" });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="alert"]'));
      },
    },
  },
});
