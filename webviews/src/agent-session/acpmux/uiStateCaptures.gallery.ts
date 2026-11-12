// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// Loading and empty states of the agent pane (ui-state-fixes M3, M7 captures), through the pane's
// own inputs: an empty state shows only once the data was read and is empty.
// M3: an existing chat whose summary has no turn count (the sidebar's listing, an older acpmux)
// is not drawn as a new chat while it attaches: it shows "Loading conversation…" where its messages
// go (ChatLoadState.tsx), and an open that is refused or never answers ends in "Couldn't load this
// conversation." with Try Again. Once its attach answered with no rows (`chatRead`) it is new, and a
// chat the host knows is new (`newSession`) has its hero at once.
// M7: the composer's `/` menu says "Loading commands…" before the chat's command list is read,
// "No commands" for a list that was read empty, "No matching commands" when nothing matches, and
// "Couldn't load commands." with Try Again when the list could not be read.
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

/// Waits for the transcript's load state (shown past CHAT_LOAD_REVEAL_MS, so a fast open never flashes it).
const chatLoadShown =
  (state: "loading" | "failed"): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(`[data-chat-load='${state}']`));
  };

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
    "agent-session/acpmux/ChatLoadState.tsx",
  ],
  variants: {
    "existing-chat-attaching": {
      note: "An existing chat whose summary has no turn count, while its attach is out: Loading conversation…, no new-chat hero, never blank.",
      snapshot: uncounted(),
      play: chatLoadShown("loading"),
    },
    "existing-chat-attach-failed": {
      note: "The same chat when its open was refused (or did not answer within 10 s): Couldn't load this conversation. with Try Again.",
      snapshot: uncounted({ connection: "failed" }),
      play: chatLoadShown("failed"),
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
    "slash-load-commands-failed": {
      note: "Play: type /zzz when the chat's command list could not be read (commandsFailed): Couldn't load commands. with Try Again.",
      snapshot: chat([], { commandsFailed: true }),
      play: slashNoMatch,
    },
    "slash-no-matching-commands": {
      note: "Play: type /zzz with a read list that has commands: No matching commands.",
      snapshot: chat([], { commands: [{ name: "review", description: "Review a pull request" }] }),
      play: slashNoMatch,
    },
  },
});
