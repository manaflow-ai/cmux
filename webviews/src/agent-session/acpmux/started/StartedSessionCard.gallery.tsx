// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { Markdown } from "../conversation/Markdown";
import { StartedMentionsContext, StartedSessionCards } from "./StartedSessionCard";
import { type StartedSession, sessionMentions } from "./startedSessions";

type Props = { started: StartedSession[]; reply?: string };

const triage: StartedSession = {
  sessionId: "child-1",
  title: "Triage the 10 failing Swift tests at the tip",
  named: true,
  state: "idle",
  harness: "claude",
};
const freeze: StartedSession = {
  sessionId: "child-2",
  title: "Switch gh-merge-green to merge-freeze issues",
  named: true,
  state: "running",
  pullRequests: { count: 2, tone: "failing", number: 22092, repo: "cmux" },
  harness: "codex",
};

/// The cards and a reply naming them, as a chat that started two chats draws them.
function GalleryStartedSessions({ started, reply }: Props) {
  const mentions = { mentions: sessionMentions(started), open: () => undefined };
  return (
    <div className="acpmux-shell">
      <div data-started-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        <StartedMentionsContext.Provider value={mentions}>
          {reply && <Markdown>{reply}</Markdown>}
          <StartedSessionCards started={started} onOpen={() => undefined} />
        </StartedMentionsContext.Provider>
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.started-sessions",
  title: "Started session cards",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-started-fixture]" }],
  covers: [
    "agent-session/acpmux/started/StartedSessionCard.tsx#StartedSessionCards",
    "agent-session/acpmux/started/StartedSessionCard.tsx#StartedSessionCard",
    "agent-session/acpmux/started/StartedSessionCard.tsx#StartedMentionsContext",
    "agent-session/acpmux/started/StartedSessionCard.tsx#StartedSessionChip",
  ],
  styles: () => import("../styles.css"),
  load: async () => GalleryStartedSessions,
  variants: {
    two: {
      note: "Two chats the agent started: one done, one running with two PRs (the branch PR's checks failing), as one card after the reply that names both as chips.",
      props: {
        started: [triage, freeze],
        reply:
          "Both are running now: Triage the 10 failing Swift tests at the tip and Switch gh-merge-green to merge-freeze issues. I'll check what each produces when it reports back.",
      },
    },
    states: {
      note: "Needs input, failed with a failing PR, and done unread with a merged PR.",
      props: {
        started: [
          { sessionId: "c-1", title: "Rename the settings keys", state: "waiting" },
          {
            sessionId: "c-2",
            title: "Fix the flaky sidebar test",
            state: "failed",
            pullRequests: { count: 1, tone: "failing", number: 22163, repo: "cmux" },
          },
          {
            sessionId: "c-3",
            title: "Bump the Ghostty pin",
            state: "idle",
            unread: true,
            pullRequests: { count: 1, tone: "merged", number: 22164, repo: "cmux" },
          },
        ],
      },
      height: 200,
    },
    harnesses: {
      note: "Each row leads with its harness's mark (Claude, Codex), and a chat on a harness with no mark of its own its chat icon in a tone stable for its id, as Session Info's child chat rows draw them.",
      props: {
        started: [
          { sessionId: "h-1", title: "Review the queue change", state: "idle", harness: "claude" },
          { sessionId: "h-2", title: "Port the retry test to Linux", state: "running", harness: "codex" },
          { sessionId: "h-3", title: "Audit the cache keys", state: "idle" },
          { sessionId: "h-4", title: "Bench the transcript rows", state: "idle" },
        ],
      },
      height: 220,
    },
  },
});
