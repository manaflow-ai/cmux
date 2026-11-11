// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// The system and tool rows of Leo's 2026-11-02 capture of a Claude chat, in order (Leo: "these are
// all so stupid looking"): the end of a reply, another agent's received line, a reply that said only
// ".", a quiet "Scheduled check", an opened "Ran 2 commands" and a compaction's note. The capture's
// compaction still ran; a running or just completed one is now the running turn's live line
// (Thinking.tsx), so the note here is one whose end was never heard, "Compaction ended", which
// keeps its own row.
// The one-line rows sit flush on the tool rows' 22 pitch with no gap between any two of them, the
// "." reply draws nothing, and every row's words start on the tool rows' text column
// (leo-workspace design/transcript-spacing.md rule 3; design/chat-transcript.md "One frame").
// test/transcript-system-rows.test.ts measures it.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { backgroundTurnLook, drawsBackgroundTurnLines } from "./backgroundTurnLook.experiment";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

const SENDER = "gcp-agent-lane-2/cloud-clouddo";
const RECEIVED = "cloud-clouddo: backend.yml is green at 4f2a91c, the candidate is ready to promote.";

const rows = () => [
  user("Promote the candidate once backend.yml is green on the lane.", 20),
  assistant(
    "I'll wait for the lane's backend.yml run, then dispatch the production promote of the candidate it built.",
    19.8,
  ),
  summary(19.7, { status: "completed", durationMs: 12_000 }),
  user(RECEIVED, 12, {
    incoming: {
      kind: "message",
      message: { name: SENDER, text: RECEIVED, raw: RECEIVED, sessionId: "s-lane", harness: "claude" },
    },
    untyped: true,
  }),
  // What Claude answered: one period (Leo's capture). It draws nothing.
  assistant(".", 11.9),
  summary(11.9, { status: "completed", durationMs: 2_000 }),
  row(BACKGROUND_TURN, 8, {
    id: backgroundTurnRowId("system-rows-scheduled"),
    background: { id: "system-rows-scheduled", trigger: "scheduled", running: false, quiet: true, hasRows: true },
  }),
  activity([run("Read the lane's last run", "gh run list -w backend.yml -L 1")], 7.9, {
    inBackground: "system-rows-scheduled",
  }),
  assistant("Nothing new yet.", 7.8, { inBackground: "system-rows-scheduled" }),
  activity(
    [
      run("Check backend.yml dispatch inputs", "gh workflow view backend.yml --yaml | rg -A6 workflow_dispatch"),
      run(
        "Dispatch production promote of the candidate",
        "gh workflow run backend.yml -f env=production -f sha=4f2a91c",
      ),
    ],
    4,
    { id: "system-rows-run" },
  ),
  row("compaction", 2, { compaction: { state: "failed", inferred: true } }),
];

/// Opens "Ran 2 commands", as Leo's capture shows it.
const openRun: Play = async (ctx) => {
  const line = () =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool[aria-expanded]")].find((node) =>
      /2/.test(node.textContent ?? ""),
    );
  await ctx.waitFor(line, { capMs: 10_000 });
  if (line()?.getAttribute("aria-expanded") === "false") line()!.click();
  await ctx.waitFor(() => ctx.document.querySelector(".cv-steps"), { capMs: 10_000 });
};

const snapshot = () => {
  const base = chat(rows(), {
    title: "cloud-promote",
    isWorking: true,
    sessions: [
      session({ sessionId: SESSION_ID, title: "cloud-promote", name: "cloud-promote" }),
      session({ sessionId: "s-lane", title: SENDER, name: SENDER }),
    ],
  });
  // A Claude chat: its turns fold per run as Claude Code's do (App.tsx reads the family).
  return { ...base, summary: { ...base.summary!, family: "claude" } };
};

export default agentPaneEntry({
  id: "agent-pane.transcript-system-rows",
  title: "Transcript system rows: received line, Scheduled check, a run and a compaction on one pitch",
  area: "Agent pane",
  height: 700,
  covers: [
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/conversation/visibleMessage.ts",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
    "agent-session/acpmux/conversation/CompactionNote.tsx",
  ],
  variants: {
    "leo-capture": {
      note: 'Leo\'s capture in order: a reply\'s end, a received line, a "." reply (draws nothing), "Scheduled check", "Ran 2 commands" opened and "Compaction ended", flush on the 22 pitch.',
      snapshot: snapshot(),
      play: openRun,
    },
    "scheduled-check-hover": {
      note: '"Scheduled check" under the pointer: its words light all the way through, as "Ran 2 commands" does, not only its chevron (Leo, 2026-11-09: "this scheduled check thing isn\'t highlighted all the way through like other tool calls are").',
      snapshot: snapshot(),
      play: async (ctx) => {
        // The line look's line (backgroundTurnLook.experiment.ts); the inline look draws none.
        if (!drawsBackgroundTurnLines()) return;
        await ctx.hover({ selector: "button.cv-background-turn .cv-agent-activity__sentence" });
      },
    },
  },
  // Compare arms: the turn's calls inline (default, Leo 2026-11-11) and the line look these variants first drew.
  experiment: {
    definition: backgroundTurnLook,
    script: [{ name: "hover the first row", run: async (ctx) => ctx.hover({ selector: ".cv-tool" }) }],
  },
});
