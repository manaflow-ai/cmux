// l10n-allow-file: gallery fixtures and comparison notes.
import { setExperimentSwitches } from "../../experiments/switches";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";

const pdf = "%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n%%EOF";
const snapshot = chat([user("Review the settings change.", 2), assistant("The review is ready.", 1)], {
  queue: [{ id: "tests", prompt: "Run the settings tests next." }],
});

function show(on: boolean, hasDraft = false) {
  return async (ctx: PlayContext) => {
    setExperimentSwitches({ composerButtonsVisible: on });
    await ctx.waitFor(() => {
      const form = ctx.document.querySelector(".acpmux-composer");
      const actions = form?.querySelector(".acpmux-queued-actions");
      if (!form || !actions) return false;
      const send = form.querySelector<HTMLButtonElement>("button.acpmux-send");
      if (!on) return !send && !form.hasAttribute("data-composer-buttons-visible");
      return send?.disabled === !hasDraft && ctx.document.defaultView!.getComputedStyle(actions).opacity === "1";
    });
  };
}

export default agentPaneEntry({
  id: "agent-pane.composer-buttons-visible",
  title: "Always show composer buttons",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/Composer.tsx", "agent-session/acpmux/ComposerQueue.tsx"],
  variants: {
    off: { note: "Empty composer with the switch off.", snapshot, play: show(false) },
    on: { note: "Empty composer with Send dimmed and queue actions visible.", snapshot, play: show(true) },
    attachment: {
      note: "A staged attachment can be removed without pointing at it.",
      snapshot,
      native: {
        "chat.draftAttachments.get": [
          {
            id: "notes",
            kind: "document",
            name: "notes.pdf",
            mimeType: "application/pdf",
            size: pdf.length,
            data: btoa(pdf),
            pageCount: 1,
          },
        ],
      },
      play: async (ctx) => {
        await show(true, true)(ctx);
        await ctx.waitFor(() => {
          const remove = ctx.document.querySelector(".acpmux-attachment-remove");
          return !!remove && ctx.document.defaultView!.getComputedStyle(remove).opacity === "1";
        });
      },
    },
    draft: {
      note: "Send becomes available in the same slot when the draft has text.",
      snapshot,
      ready: { draft: "Check the default settings too." },
      play: show(true, true),
    },
  },
});
