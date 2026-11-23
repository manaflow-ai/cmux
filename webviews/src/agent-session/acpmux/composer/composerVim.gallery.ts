// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Vim mode in the chat composer (Settings' agentPane.vimMode; composer/composerVim.ts): the NORMAL or
// INSERT tag before Send. `insert` is the prompt as it opens with vim mode on; `normal` is after Esc.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import { setComposerSettings } from "../composerSettings";

const startedChat = () =>
  chat([
    user("Add a DELETE /todos/:id endpoint and one focused test using the existing test setup.", 12),
    assistant("Added `DELETE /todos/:id` and a test that deletes an item and checks the list.", 11),
  ]);

const DRAFT = { draft: "Now add the same endpoint for tags, with its test." };

async function vim(ctx: PlayContext, normal: boolean) {
  setComposerSettings({ vimMode: true });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-vim-mode"));
  if (!normal) return;
  await ctx.focus({ selector: ".acpmux-composer-prompt [contenteditable='true']" });
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-vim-mode[data-vim-mode="normal"]'));
}

export default agentPaneEntry({
  id: "agent-pane.composer-vim-mode",
  title: "Composer: vim mode",
  area: "Agent pane",
  height: 320,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["agent-session/acpmux/composer/VimModeTag.tsx#VimModeTag"],
  variants: {
    insert: {
      note: "Vim mode on, typing: the muted INSERT tag before Send; Enter sends as always.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => vim(ctx, false),
    },
    normal: {
      note: "After Esc: NORMAL in the accent, and h j k l, w b e, dd, cw and the rest edit the prompt instead of typing.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => vim(ctx, true),
    },
  },
});
