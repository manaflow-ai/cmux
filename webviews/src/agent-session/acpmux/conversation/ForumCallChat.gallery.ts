// l10n-allow-file: gallery fixtures (sample asks, titles and replies), not shipped UI.
// A forum post, reply and search in a chat (forumCalls.ts, ForumCallCard.tsx): each its own card in
// place of the raw MCP row, whichever harness made the call. The looks side by side are
// agent-pane.forum-call-looks.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import { codexPostCall, postCall, replyCall, searchCall, unconfiguredCall } from "./forumCalls.fixtures";

export default agentPaneEntry({
  id: "agent-pane.forum-call",
  title: "Forum tool call in a chat",
  area: "Agent pane",
  experimental: true,
  height: 560,
  covers: ["agent-session/acpmux/conversation/ForumCallCard.tsx", "agent-session/acpmux/conversation/forumCalls.ts"],
  variants: {
    claude: {
      note: "A Claude chat searched the forum, replied on the thread it found and posted a finding: three cards.",
      snapshot: chat(
        [
          user("The compile pool drained again. Check the forum first, then write it up for the team.", 4),
          activity([searchCall()], 3.6),
          activity([replyCall()], 3.2),
          activity([postCall()], 3),
          assistant("Replied on #198 and posted the drain as a finding in fleet (#214).", 2.8),
        ],
        { title: "Compile pool drain", branch: "lane/pool-drain" },
      ),
    },
    codex: {
      note: "A Codex chat's post (its input nests the server and tool): the same card.",
      snapshot: chat([user("Post the pool drain to fleet.", 3), activity([codexPostCall()], 2.8)], {
        title: "Compile pool drain",
        harness: "codex",
        model: "gpt-6.1-sol",
      }),
    },
    running: {
      note: "The post still runs: the line names the space, the title comes from the call's arguments.",
      snapshot: chat([user("Post the pool drain to fleet.", 3), activity([postCall("in_progress")], 2.8)], {
        isWorking: true,
      }),
    },
    "no-match": {
      note: "A search with no hits: one quiet line.",
      snapshot: chat([
        user("Has anyone written up cargo cache misses?", 3),
        activity([searchCall("completed", [])], 2.8),
      ]),
    },
    "not-set-up": {
      note: "The machine has no forum team or key: the call failed with the server's message.",
      snapshot: chat([user("Post the pool drain to fleet.", 3), activity([unconfiguredCall()], 2.8)]),
    },
  },
});
