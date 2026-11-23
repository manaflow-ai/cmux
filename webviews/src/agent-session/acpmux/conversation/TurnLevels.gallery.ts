// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A turn's two levels (Leo, 2026-11-07: "do you think we should distinguish the absolute top level
// one versus the inner ones that are interrupted by your little asides in between?"). The outer
// level is the whole turn, its "Worked for" line counting every call ("Worked for 2m 17s · 9 tool
// calls"); the inner levels are the runs of calls between the agent's short asides, each counting
// only its own calls and never joining another across an aside (toolGroups.ts `isAside`). A line
// the reader opened stays open while calls join it and when the turn ends (TurnRows.tsx
// `runDisclosureKey`). The arms compare how the inner lines sit under the opened outer one
// (`data-turn-levels-look`, conversation.css): `outer-line`, shipped, keeps them at their own weight;
// `indented` sets them in and dims them; `guide` hangs them on a rule. `live` is the same turn while
// it runs: nothing folds yet (cmux#38339), so there is no outer line and no run line, each call in
// sight in its group and each aside its own paragraph.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity } from "../model";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const read = (path: string): AcpmuxActivity => tool(`Read ${path}`, "read", "completed", { output: "…\n" });

function work() {
  return [
    user("Land the approved fix once the merge check passes", 20),
    activity(
      [
        run("Pulled the latest approvals", "git pull -q --ff-only"),
        run("Read the approval record", "cat machines/main-merge-approvals.json"),
        read("tools/merge_hold.py"),
        run("Committed the approval", "git commit -qam 'record approval'"),
        run("Pushed it", "git push -q"),
      ],
      19,
    ),
    // A short aside (under SHORT_NOTE_CHARS): it joins the rows around it into one, and splits the runs.
    assistant("Approval recorded. Now merging pinned, re-running the merge check first if needed:", 15),
    activity(
      [
        run("Merged the pull request", "gh pr merge 101 --squash --match-head-commit 3f2a9c1"),
        run("Checked the record landed", "grep -c 101 machines/main-merge-approvals.json"),
        run("Listed the synced tools", "ls ~/.local/share/sync/"),
      ],
      12,
    ),
    assistant("Another short aside before the last check:", 9),
    activity([run("Read the sync job", "plutil -p ~/Library/LaunchAgents/sync.plist")], 8),
  ];
}

function ended() {
  return [
    ...work(),
    assistant("Merged at 3f2a9c1; the approval record and the sync job are both in place.", 6),
    summary(5.8, { status: "completed", durationMs: 137_000, toolCount: 9 }),
  ];
}

/// A Claude chat: the family picks the turn's fold (turnFoldStyle.ts), whose outer line counts the calls.
function claude(live: boolean) {
  const base = chat(live ? work() : ended(), { title: "Land the approved fix", harness: "claude", isWorking: live });
  return { ...base, summary: { ...base.summary!, family: "claude" } };
}

/// Opens the turn's "Worked for" line, so its inner run lines show.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (look: string | undefined, note: string, live = false): AgentPaneVariant => ({
  note,
  snapshot: claude(live),
  ...(look ? { documentAttributes: { "turn-levels-look": look } } : {}),
  ...(live ? {} : { play: openWorked }),
});

export default agentPaneEntry({
  id: "agent-pane.turn-levels",
  title: "Turn levels: outer fold and inner runs",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor",
    "agent-session/acpmux/conversation/TurnRows.tsx#ToolRows",
  ],
  variants: {
    "outer-line": variant(
      undefined,
      "Shipped: the outer line counts the whole turn; opened, each run between the asides keeps its own line and count at its own weight.",
    ),
    indented: variant("indented", "Inner run lines set in by one icon box and dimmed under the opened outer line."),
    guide: variant("guide", "Inner run lines hung on a rule from the outer line's glyph."),
    live: variant(
      undefined,
      "The same turn while it runs: nothing folds until it ends, each call in sight and each aside its own paragraph.",
      true,
    ),
  },
});
