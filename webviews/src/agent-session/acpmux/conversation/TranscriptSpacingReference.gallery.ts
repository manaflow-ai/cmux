// l10n-allow-file: gallery fixtures (sample prompts, replies, lane names and commands), not shipped UI.
// The transcript's vertical spacing as the NEXT nightly of 2026-10-30 drew it (Leo, 2026-11-01, on a
// capture of that build: "i like this spacing kinda i prefer it to what we have now tho it's just
// minor differences"). Three settled turns, as a long session reads after a reload: a reply and a
// subagent's end; a prompt, a message to another agent and a three-paragraph reply; a prompt, a run
// of commands, a short reply, a second run, an answered question card, and the next prompt.
// transcript-spacing-reference.test.ts measures each gap against the values that build drew
// (design/chat-transcript.md "Transcript spacing").
import answered from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-collapsed.json";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../../gallery/format";
import type { AgentQuestion } from "../question/model";
import { QUESTION_RECORD } from "../question/record";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";

const command = (line: string) => tool(line, "execute", "completed", { command: line });
const send = (target: string, text: string) =>
  tool(`acpmux send --no-wait ${target} '${text}'`, "execute", "completed", {
    command: `acpmux send --no-wait ${target} '${text}'`,
    description: `Tell ${target}`,
    output: "queued",
  });

const cacheFix: Subagent = {
  id: "agent-cache-fix",
  parent: null,
  name: "Fixed the stale release cache",
  task: "Fix the stale release cache",
  state: "completed",
  startedAt: minutesAgo(31),
  endedAt: minutesAgo(30.5),
};

const REPLY =
  "The docs half of the release page passed review. It merges once its queued checks finish, and the changelog PR right after it.";
const BACK = [
  "I'm here. The editor restarted, which can stop background lanes partway through. Their saved progress is kept, so I can pick them up where they left off.",
  "I've restarted the lane fixing the stale release cache first, since other lanes queue behind that problem. It checks what it already pushed before going on, so nothing gets done twice.",
  "The other lanes may have stopped in the restart too: search speed, the importer, the nightly notes, the theme pass and the settings work. I didn't restart them all at once; my plan is to bring them back one at a time, starting with whichever is closest to landing.",
].join("\n\n");

const rows = [
  user("Where is the release page?", 32),
  assistant(REPLY, 31.5),
  row(SUBAGENTS, 30.5, { subagents: [cacheFix] }),
  user("are you there?", 20),
  activity([send("cache-fix", "Pick up the stale release cache where you left off.")], 19.9),
  assistant(BACK, 19.8),
  user("we should regroup since it's been over an hour since the first report", 10),
  activity(
    [
      command("git status"),
      command("git log --oneline -5"),
      command("gh pr list --limit 20"),
      command("rg -n release docs"),
      command("bun run check"),
    ],
    9.9,
  ),
  assistant("I'm reading the release dashboard to put together a short digest.", 9.8),
  activity(
    [command("gh run list --limit 5"), command("git fetch"), command("bun test"), send("cache-fix", "Status?")],
    9.7,
  ),
  row(QUESTION_RECORD, 9.6, { question: answered as unknown as AgentQuestion }),
  user("Yes, ship it", 9),
];

export default agentPaneEntry({
  id: "agent-pane.transcript-spacing-reference",
  title: "Transcript spacing (the 2026-10-30 rhythm)",
  area: "Agent pane",
  height: 1400,
  covers: ["agent-session/acpmux/conversation/conversation.css"],
  variants: {
    shipped: {
      note: "Three settled turns: a reply and a subagent's end; a prompt, a sent message and three paragraphs; a prompt, a run, a short reply, a run, an answered question and the next prompt. The gaps between them are the 2026-10-30 nightly's.",
      snapshot: chat(rows, { title: "Release check" }),
    },
  },
});
