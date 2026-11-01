// l10n-allow-file: gallery fixtures (sample prompts, replies, lane names and commands), not shipped UI.
// The transcript's vertical spacing as Leo's capture of a NEXT build from about 2026-10-30 drew it
// (Leo, 2026-11-01: "i like this spacing kinda i prefer it to what we have now tho it's just minor
// differences"). One long running turn in the capture's shape, with stand-in text: a two-line reply
// and a harness notice under it; a steer, a message to another agent and three paragraphs; a second
// steer, a run of commands, a one-line reply, a second run, an answered question and its answer.
// transcript-spacing-reference.test.ts measures each gap, ink to ink, against the capture's
// (design/chat-transcript.md "Transcript spacing").
import answered from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/answered-collapsed.json";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../../gallery/format";
import type { AgentQuestion } from "../question/model";
import { QUESTION_RECORD } from "../question/record";

const command = (line: string) => tool(line, "execute", "completed", { command: line });
const send = (target: string, text: string) =>
  tool(`acpmux send --no-wait ${target} '${text}'`, "execute", "completed", {
    command: `acpmux send --no-wait ${target} '${text}'`,
    description: `Tell ${target}`,
    output: "queued",
  });

const REPLY =
  "The docs half of the release page passed review. It merges once its queued checks finish, and the changelog PR for the same release goes in right after it, once its own checks are green too.";
const BACK = [
  "I'm here. The editor restarted, which can stop background lanes partway through. Their saved progress is kept, so I can pick them up where they left off when they come back.",
  "I've restarted the lane fixing the stale release cache first, since other lanes queue behind that problem. It checks what it already pushed before going on, so nothing gets done twice.",
  "The other lanes may have stopped in the restart too: search speed, the importer, the nightly notes, the theme pass and the settings work. I didn't restart them all at once, because that would load the machine up again. My plan is to bring them back one at a time, starting with whichever is closest to landing.",
].join("\n\n");

const steer = (text: string, minutes: number) => user(text, minutes, { steer: "landed" });

const rows = [
  user("Where is the release page?", 32),
  assistant(REPLY, 31.5),
  user("", 30.5, { incoming: { kind: "notice", text: "Fixed the stale release cache · took 32s" }, untyped: true }),
  steer("are you there?", 20),
  activity([send("cache-fix", "Pick up the stale release cache where you left off.")], 19.9),
  assistant(BACK, 19.8),
  steer("we should regroup since it's been over an hour since the first report came in this morning", 10),
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
  steer("Yes, ship it", 9),
];

export default agentPaneEntry({
  id: "agent-pane.transcript-spacing-reference",
  title: "Transcript spacing (the 2026-10-30 rhythm)",
  area: "Agent pane",
  height: 1400,
  covers: ["agent-session/acpmux/conversation/conversation.css"],
  variants: {
    shipped: {
      note: "One running turn in the shape of Leo's capture: a reply and a notice; a steer, a sent message and three paragraphs; a steer, a run, a one-line reply, a run, an answered question and its answer.",
      snapshot: chat(rows, { title: "Release check", isWorking: true }),
    },
  },
});
