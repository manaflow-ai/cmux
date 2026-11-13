// l10n-allow-file: gallery fixtures (sample prompts, commands, replies and helper names), not shipped UI.
// A background turn's one quiet line cites its task: the helper that ran it and its command as typed
// (Leo, 2026-11-05: "cite the helper/add atribution (like how ive gradually pushed for more andd more
// of that a la deeplinks and communicating in acpmux) and display the actual code in the raw or
// something"). test/background-turn-attribution.test.ts checks where the citation comes from.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxBackgroundCause, AcpmuxBackgroundSource } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const opening = [
  user("Run the migration tests in the background and tell me if anything breaks", 12, { id: "src-prompt" }),
  assistant("Started them in the background. I'll report when they finish.", 11.9, { id: "src-reply" }),
  summary(11.9, { id: "src-footer", status: "completed", durationMs: 4_000 }),
];

const failed: AcpmuxBackgroundCause = {
  kind: "shell",
  status: "failed",
  weight: "failure",
  origin: "src-call",
  summary: "Background command failed (exit code 1)",
};

const line = (
  id: string,
  extra: { source?: AcpmuxBackgroundSource; cause?: AcpmuxBackgroundCause; running?: boolean; trigger?: string },
) =>
  row(BACKGROUND_TURN, 8, {
    id: backgroundTurnRowId(id),
    background: {
      id,
      trigger: extra.trigger ?? "task_notification",
      running: extra.running ?? false,
      ...(extra.running ? {} : { quiet: true }),
      ...(extra.cause && { cause: extra.cause }),
      ...(extra.source && { source: extra.source }),
    },
  });

export default agentPaneEntry({
  id: "agent-pane.background-turn-source",
  title: "Background turn line: its helper and raw command",
  area: "Agent pane",
  height: 300,
  covers: ["agent-session/acpmux/conversation/BackgroundTurnLine.tsx"],
  variants: {
    before: {
      note: "Before: the line names only what happened, not which task or who ran it.",
      snapshot: chat([...opening, line("src-before", { cause: failed })]),
    },
    command: {
      note: "The chat's own shell: the notification's words, then the command as typed, raw, in the code face.",
      snapshot: chat([...opening, line("src-command", { cause: failed, source: { command: "bun test migrations" } })]),
    },
    helper: {
      note: "A helper's shell: the helper is a link that opens its transcript, then its command.",
      snapshot: chat([
        ...opening,
        line("src-helper", {
          cause: { ...failed, kind: "subagent_step" },
          source: {
            command: "bun test migrations/0042.test.ts",
            ownerId: "src-agent",
            ownerTitle: "Explore migrations",
          },
        }),
      ]),
    },
    running: {
      note: "While the turn runs: the spinner and shimmering words, then the citation.",
      snapshot: chat([
        ...opening,
        line("src-running", {
          running: true,
          cause: { kind: "shell", status: "completed", weight: "result", origin: "src-call" },
          source: { command: "cargo test -p acpmux --lib", ownerId: "src-agent", ownerTitle: "Review" },
        }),
      ]),
    },
    "long-command": {
      note: "A long command gives way first: the words and the helper stay, the command ends in an ellipsis (see it at the narrow width).",
      snapshot: chat([
        ...opening,
        line("src-long", {
          cause: failed,
          source: {
            command:
              "cmux-ci test -- bash -c 'cd webviews && bun test test/background-turn-attribution.test.ts test/agent-pane-background-turns.test.ts'",
            ownerId: "src-agent",
            ownerTitle: "Explore",
          },
        }),
      ]),
    },
  },
});
