// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Vim keys in the composer (agentPane.composerVimKeys, composer/vimKeys.ts): the prompt's NORMAL and
// INSERT modes with the indicator in the box's corner. `off` is the default: no indicator, no key read.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { setComposerSettings } from "./composerSettings";

const snapshot = () =>
  chat(
    [
      user("Add a DELETE /todos/:id endpoint and one focused test using the existing test setup.", 12),
      assistant("Added `DELETE /todos/:id` and a test that deletes an item and checks the list.", 11),
    ],
    {},
  );

const DRAFT = { draft: "Keep the change tiny.\nDo not touch the schema." };

async function typed(ctx: PlayContext, on: boolean) {
  setComposerSettings({ composerVimKeys: on });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
}

export default agentPaneEntry({
  id: "agent-pane.composer-vim",
  title: "Composer: vim keys",
  area: "Agent pane",
  height: 300,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/composer/vimKeys.ts"],
  variants: {
    insert: {
      note: "Vim keys on, a draft typed: INSERT in the box's top right; Return still sends.",
      snapshot: snapshot(),
      ready: DRAFT,
      play: (ctx) => typed(ctx, true),
    },
    normal: {
      note: "Esc in the prompt: NORMAL, the caret back on a character; plain keys move or edit, none type.",
      snapshot: snapshot(),
      ready: DRAFT,
      play: async (ctx) => {
        await typed(ctx, true);
        await ctx.focus({ selector: ".acpmux-md-root" });
        await ctx.press("Escape");
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-vim-mode[data-vim-mode="normal"]'));
      },
    },
    off: {
      note: "The default (agentPane.composerVimKeys off): no indicator, and Esc and every letter are the composer's.",
      snapshot: snapshot(),
      ready: DRAFT,
      play: (ctx) => typed(ctx, false),
    },
  },
});
