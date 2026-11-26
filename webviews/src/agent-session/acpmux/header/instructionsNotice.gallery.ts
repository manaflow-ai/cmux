// l10n-allow-file: gallery fixtures, not shipped UI.
// The chat menu's Edit CLAUDE.md when the app can't open the file: a notice above the composer
// says why, with Dismiss, instead of nothing happening. Only a failure asking again may clear has
// Retry (retry-prompt-ok: it opens the file, which the app does only on a click in the pane).
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
      note: "Play: Edit CLAUDE.md when CLAUDE.md links out of the chat folder: a notice says it is outside the chat's folders, with Dismiss only (asking again gets the same refusal), and Dismiss clears it.",
      snapshot,
      native: { "project.instructions": { nativeError: { code: "transport.path_outside_roots" } } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.click({ role: "menuitem", name: "Edit CLAUDE.md" });
        await ctx.waitFor(() =>
          ctx.document.querySelector('[role="alert"]')?.textContent?.includes("outside the folders this chat can open"),
        );
        if (ctx.document.querySelector(".acpmux-instructions-notice button:not([data-notice-action])"))
          throw new Error("a refusal asking again cannot clear offers Retry");
        await ctx.click({ selector: '.acpmux-instructions-notice button[data-notice-action="dismiss"]' });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="alert"]'));
      },
      checks: {
        layoutShiftMax: {
          value: 0.06,
          reason:
            "The notice joins and leaves the bottom stack, which lies over the transcript's foot (bottomStack.css): the stack's unpainted wrapper (div.acpmux-dock, the only source) grows and shrinks from its top, 0.040 measured each way; the composer and the rows do not move.",
        },
      },
    },
    "open-failed": {
      note: "Play: Edit CLAUDE.md when the app could not open it for another reason: Retry (a click, so the app may open the file) asks again, Dismiss clears it.",
      snapshot,
      native: { "project.instructions": { nativeError: { code: "native.internal" } } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.click({ role: "menuitem", name: "Edit CLAUDE.md" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-instructions-notice") !== null);
        // The notice's own Retry (the transcript's turn has a Retry too).
        await ctx.click({ selector: ".acpmux-instructions-notice button:not([data-notice-action])" });
        // Poll by hand so a failure says what the host was asked.
        for (let tries = 0; asked(ctx) < 2; tries++) {
          if (tries > 60) {
            const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: Log }).cmuxGalleryLog;
            throw new Error(`Retry asked nothing: ${JSON.stringify(log.map(({ method }) => method))}`);
          }
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        await ctx.click({ selector: '.acpmux-instructions-notice button[data-notice-action="dismiss"]' });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="alert"]'));
      },
      checks: {
        layoutShiftMax: {
          value: 0.06,
          reason:
            "The notice joins and leaves the bottom stack, which lies over the transcript's foot (bottomStack.css): the stack's unpainted wrapper (div.acpmux-dock, the only source) grows and shrinks from its top, 0.040 measured each way; the composer and the rows do not move.",
        },
      },
    },
  },
});
