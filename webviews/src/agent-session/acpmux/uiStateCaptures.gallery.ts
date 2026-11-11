// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Loading and empty states of the agent pane (ui-state-fixes M3, M7 captures), through the pane's
// own inputs: an empty state shows only once the data was read and is empty.
// M3: an existing chat whose summary has no turn count (the sidebar's listing, an older acpmux)
// is not drawn as a new chat while it attaches; once its attach answered with no rows (`chatRead`)
// it is, and a chat the host knows is new (`newSession`) has its hero at once.
// M7: the composer's `/` menu says "Loading commands…" before the chat's command list is read,
// "No commands" for a list that was read empty, "No matching commands" when nothing matches.
import { agentPaneEntry } from "../../gallery/format";
import { chat, noChat } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";

/// A chat with no rows whose summary has no turn count.
function uncounted(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const snapshot = chat([], { title: "Fix the flaky sidebar drag test", ...fields });
  if (snapshot.summary) delete snapshot.summary.turnCount;
  return snapshot;
}

/// Types `/zzz` in the prompt; the slash menu opens with its empty line (no command matches).
const slashNoMatch: Play = async (ctx) => {
  await ctx.click({ selector: "[contenteditable='true']" });
  await ctx.type("/zzz");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-slash-empty"));
};

export default agentPaneEntry({
  id: "agent-pane.ui-state-captures",
  title: "Loading before empty: chat attach and slash commands",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 760, wide: 760 },
  covers: [
    "agent-session/acpmux/emptyStateModel.ts",
    "agent-session/acpmux/composerModel.ts",
  ],
  variants: {
    "existing-chat-attaching": {
      note: "An existing chat whose summary has no turn count, while its attach is out: no new-chat hero.",
      snapshot: uncounted(),
    },
    "existing-chat-read-empty": {
      note: "The same chat once its attach answered with no rows and no older history (chatRead): it has no turns, the hero shows.",
      snapshot: uncounted({ chatRead: true }),
    },
    "new-chat-hero": {
      note: "A real new chat (the host's newSession, no session yet): the new-chat hero.",
      ready: { newSession: true },
      snapshot: noChat([]),
    },
    "slash-loading-commands": {
      note: "Play: type /zzz before the chat's command list was read (commandsPending): Loading commands…",
      snapshot: chat([], { commandsPending: true }),
      play: slashNoMatch,
    },
    "slash-no-commands": {
      note: "Play: type /zzz once the chat's command list was read empty: No commands.",
      snapshot: chat([], { commands: [] }),
      play: slashNoMatch,
    },
    "slash-no-matching-commands": {
      note: "Play: type /zzz with a read list that has commands: No matching commands.",
      snapshot: chat([], { commands: [{ name: "review", description: "Review a pull request" }] }),
      play: slashNoMatch,
    },
  },
});
