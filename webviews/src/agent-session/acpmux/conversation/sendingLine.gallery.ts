// l10n-allow-file: gallery fixtures (sample commands, session names and messages), not shipped UI.
// A running turn's live line while its call in flight sends another agent a message (Thinking.tsx,
// conversation/turns.ts `sendingTo`): "Sending message to <target>", never the raw `acpmux send …`
// line. The shell call has the shape Claude Code recorded through acpmux on 2026-10-21
// (`_meta.claude.tool: "Bash"`, kind `execute`, the command cut to its title, the model's
// description); names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, session, tool, user, SESSION_ID } from "../../../gallery/fixtures/acpmux";

const REPORT =
  "Merged #4182 (retry banner shows once per outage). The review passed; its one red, the release notary, is red on base too.";

const shellSend = (command: string, description: string) =>
  tool(command.slice(0, 120), "execute", "in_progress", { command, description });

const CHILD = session({
  sessionId: "sub-tests",
  title: "Own the tests lane",
  name: "claude-sr2/tests",
  shortName: "tests",
  startedBy: SESSION_ID,
  lane: "working",
  indicator: "working",
  status: "running",
});

export default agentPaneEntry({
  id: "agent-pane.sending-line",
  title: "Sending a message, on the live line",
  area: "Agent pane",
  height: 320,
  covers: ["agent-session/acpmux/conversation/Thinking.tsx", "agent-session/acpmux/conversation/acpmuxSends.ts"],
  variants: {
    shell: {
      note: 'A shell `acpmux send` that waits for the reply, in flight: the live line reads "Sending message to coord-deputy" with its time.',
      snapshot: chat(
        [
          user("Report the merge and wait for the deputy's answer.", 1),
          activity([shellSend(`acpmux send coord-deputy '${REPORT}'`, "Report merge to coord-deputy")], 0.8),
        ],
        { title: "net-retries", isWorking: true },
      ),
    },
    reach: {
      note: "The same through reach and a perl alarm: the session reads host/name.",
      snapshot: chat(
        [
          user("Ask the reviewer on build-box to look again.", 1),
          activity(
            [
              shellSend(
                `reach build-box 'perl -e "alarm 60; exec @ARGV" acpmux send review-astra "Re-review #4182 at 9c1e0f2."'`,
                "Ask the reviewer on build-box to look again",
              ),
            ],
            0.8,
          ),
        ],
        { title: "net-retries", isWorking: true },
      ),
    },
    subsession: {
      note: "A sub-session's send_message in flight: the line names the sub-session from the session list.",
      snapshot: (() => {
        const snapshot = chat(
          [
            user("Tell tests to cover the backoff.", 1),
            activity(
              [
                tool("mcp__cmux-subsessions__send_message", "other", "in_progress", {
                  inputSummary: JSON.stringify({ sessionId: "sub-tests", text: "Also cover the retry backoff." }),
                }),
              ],
              0.8,
            ),
          ],
          { title: "net-retries", isWorking: true },
        );
        return { ...snapshot, sessions: [...snapshot.sessions, CHILD] };
      })(),
    },
  },
});
