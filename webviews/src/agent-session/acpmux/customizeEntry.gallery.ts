// l10n-allow-file: gallery fixtures, not shipped UI.
// Customize… (the palette and the app menu, `customize.open`): where the chat it opens shows, with
// `/customize ` already in its composer (customizeCommand.ts turns what follows into the ask). The
// app opens the first variant (CmuxNextAgentPane AgentPaneCustomize.swift); the others are the placements compared.
// References (cmux-design-references): an editor's customize mode drawn beside the work, an agents
// window that lists customizations next to the agent, and a launcher's quick floating ask.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { CWD, noChat } from "../../gallery/fixtures/acpmux";

const DRAFT = "/customize ";

/// The composer shows the command with the caret after it, ready for the wish.
const holdsTheCommand = async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector(".acpmux-composer [contenteditable='true'], .nt-field");
    return field?.textContent?.includes("/customize") ?? false;
  });
};

/// The wish typed after it: the slash menu explains the command (ask, watch it change, apply).
const typesAWish = async (ctx: PlayContext) => {
  await holdsTheCommand(ctx);
  await ctx.type("make the sidebar compact");
  await ctx.waitFor(() => ctx.document.body.textContent?.includes("make the sidebar compact") ?? false);
};

export default agentPaneEntry({
  id: "agent-pane.customize-entry",
  title: "Customize… opens a chat ready for the wish",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 720, wide: 1000 },
  covers: ["agent-session/acpmux/customizeCommand.ts"],
  variants: {
    "a-chat-dock": {
      note: "Picked: a new chat where New Agent Chat opens one (the chat dock), so the window it changes stays in view; Return asks, and /customize apply, discard or rollback in the same chat finish it.",
      ready: { newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: holdsTheCommand,
    },
    "a-chat-dock-wish": {
      note: "The picked placement with the wish typed: one Return from the ask.",
      ready: { newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: typesAWish,
    },
    "b-quick-composer": {
      note: "Compared: the Start Agent panel over the app. Return sends the chat to the sidebar in the background, so Apply means finding it again.",
      ready: { surface: "quick", newSession: true, cwd: CWD, draft: DRAFT },
      snapshot: noChat([]),
      play: holdsTheCommand,
    },
    "c-new-tab-page": {
      note: "Compared: the New Tab page in the focused pane. It covers that pane, often the very thing being customized.",
      ready: {
        newTab: {
          layout: "b",
          kind: "agent",
          cwd: CWD,
          home: "/Users/you",
          lastAgent: "claude",
          template: "minimal",
          draft: DRAFT,
        },
        newSession: true,
      },
      snapshot: noChat([]),
      play: holdsTheCommand,
    },
  },
});
