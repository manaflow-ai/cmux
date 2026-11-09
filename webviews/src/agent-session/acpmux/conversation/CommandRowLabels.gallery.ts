// l10n-allow-file: gallery fixtures (sample prompts, commands and outputs), not shipped UI.
// Command rows that say what the command did (Leo, 2026-11-07: "it's not just you ran a command.
// It's that you ran a specific thing"; commandActions.ts). One working turn: Leo's two memory
// searches as he saw them under "Ran 2 commands", a mixed run (git, rg, a read, gh, an unknown
// make), a heredoc script only its description names, two reads, and two compound commands (Leo's ffmpeg pipeline, a `cd && H=$(…); gh pr merge`). Compare arms shows the
// `command-label-look` experiment: the verb table first (default), the description first, the verb
// with the dimmed command, the cleaned line, and the line as typed (the look before).
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxActivity } from "../model";
import { commandLabelLook } from "./commandLabel.experiment";

const times = (at: number) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - 0.01) });

const shell = (command: string, description: string | undefined, output: string, at: number): AcpmuxActivity =>
  tool(command, "execute", "completed", {
    command,
    ...(description ? { description } : {}),
    output,
    exitCode: 0,
    ...times(at),
  });

const HEREDOC = `python3 - <<'EOF'
import json
strings = json.load(open("webviews/src/agent-session/acpmux/Localizable.xcstrings"))["strings"]
print(sum(1 for key in strings if key.startswith("tools.")))
EOF`;

/// Leo's compound command (2026-11-07 screenshot, "Ran 0*.mov) …" before): an assignment that only
/// feeds `$V`, then ffmpeg piped into an inline script. It reads "Ran ffmpeg → python3 on *.mov".
const FFMPEG = `V=$(ls "$HOME/Library/Application Support/cmux/Chat Uploads/sessions/s1/0/"*.mov); ffmpeg -v error -i "$V" -vf "format=gray" -f rawvideo - 2>/dev/null | python3 -c "
import sys
data = sys.stdin.buffer.read()
print(len(data) // (64 * 36))
"`;
const MERGE = `cd ~/wt/x && H=$(git rev-parse HEAD); echo $H; gh pr merge 32695 --squash --match-head-commit $H 2>&1 | tail -5`;

/// The turn, with Claude's descriptions on its calls or (Codex) none.
const turn = (harness: "claude" | "codex") => {
  const said = (description: string) => (harness === "claude" ? description : undefined);
  return chat(
    [
      user("Is agent-memory search ours? And make the tooltip wrap like we said before.", 9),
      activity(
        [
          shell(
            `agent-memory search "tooltip wrap width leo ask" 2>/dev/null | head -12 | cut -c1-220`,
            said("Search prior tooltip work"),
            "mem-1  2026-10-20  Leo: tooltips wrap at 280px, never one long line\n",
            8.9,
          ),
          shell(
            `agent-memory search "better tooltips" 2>/dev/null | head -10 | cut -c1-220`,
            said("Search earlier tooltip asks"),
            "mem-7  2026-10-13  Leo: a tooltip only names a control that shows no text\n",
            8.8,
          ),
        ],
        8.9,
      ),
      assistant("Both notes agree on the width. Now the code that draws it.\n\nLooking at the tooltip now.", 8.7),
      activity(
        [
          shell("git status --short", said("Check the worktree"), " M webviews/src/ui/Tooltip.tsx\n", 8.6),
          shell(
            `rg -n "maxWidth" webviews/src/ui`,
            said("Find the tooltip width"),
            "ui/Tooltip.tsx:41:  maxWidth: 320,\n",
            8.5,
          ),
          shell(
            "sed -n '30,60p' webviews/src/ui/Tooltip.tsx",
            said("Read the tooltip"),
            "export function Tooltip(…)\n",
            8.4,
          ),
          shell(
            "gh pr view 36940 --json title -q .title",
            said("Read the parity PR's title"),
            "codex parity: tool calls\n",
            8.3,
          ),
          shell("make -j8 lint 2>&1 | tail -20", said("Lint the web code"), "ok\n", 8.2),
        ],
        8.6,
      ),
      assistant("The width is a literal. Counting the strings it touches first.\n\nOne script for that.", 8.1),
      activity([shell(HEREDOC, said("Count the tool strings"), "212\n", 8)], 8),
      assistant("212 strings. Reading the two spec files.\n\nThen the fix.", 7.9),
      activity(
        [
          shell("cat design/hover-cards.md", said("Read the hover card spec"), "# Hover cards\n", 7.8),
          shell("head -40 design/components/tooltip.md", said("Read the tooltip spec"), "# Tooltip\n", 7.7),
        ],
        7.8,
      ),
      assistant("Both specs say 280px. Checking the recording frames, then merging.", 7.6),
      activity(
        [
          shell(FFMPEG, undefined, "142\n", 7.5),
          shell(MERGE, undefined, "✓ Squashed and merged pull request #32695\n", 7.4),
        ],
        7.5,
      ),
    ],
    {
      isWorking: true,
      title: "Tooltip wrap width",
      harness,
      model: harness === "codex" ? "gpt-5.5-codex" : "claude-opus-5-5",
    },
  );
};

/// Opens every closed run and command group, so each row's label shows.
const openRuns: Play = async (ctx) => {
  for (let pass = 0; pass < 4; pass += 1) {
    const closed = [
      ...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool.is-run[aria-expanded='false']"),
    ];
    if (!closed.length) break;
    for (const button of closed) button.click();
    await ctx.waitFor(() => ctx.document.querySelector(".cv-steps, .cv-step"), { capMs: 5_000 });
  }
};

export default agentPaneEntry({
  id: "agent-pane.command-row-labels",
  title: "Command rows say what the command did",
  area: "Agent pane",
  height: 1080,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/conversation/CommandRow.tsx", "agent-session/acpmux/conversation/commandActions.ts"],
  keywords: ["command", "bash", "description", "ran", "verb", "agent-memory", "shell"],
  variants: {
    claude: {
      note: 'Chosen (verbs): Leo\'s two searches read "Searched memory twice", opened to "Searched memory for “…”"; a known command reads as its verb, an unknown one ("make -j8") as its cleaned line, the heredoc as its description.',
      snapshot: turn("claude"),
      play: openRuns,
    },
    codex: {
      note: "The same turn from Codex, which sends no descriptions: the table names the same rows; the heredoc reads as its first line.",
      snapshot: turn("codex"),
      play: openRuns,
    },
    closed: {
      note: "The runs as the turn first draws them: the group lines alone.",
      snapshot: turn("claude"),
    },
  },
  experiment: { definition: commandLabelLook, script: [{ name: "open the runs", run: openRuns }] },
});
