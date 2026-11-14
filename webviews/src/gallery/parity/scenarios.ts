// l10n-allow-file: development workbench labels, not shipped UI.
import type { GalleryBackground } from "../env";

export type Scenario = {
  id: string;
  group: string;
  title: string;
  entry: string;
  source: string;
  variant: string;
  inspect: string;
  script?: "streaming" | "tools" | "error";
  background?: GalleryBackground;
};

const conversation = "src/agent-session/acpmux/conversation/";
const subagents = "src/agent-session/acpmux/subagents/";
const transcript = (id: string, group: string, title: string, variant: string, inspect: string): Scenario => ({
  id,
  group,
  title,
  variant,
  inspect,
  entry: "agent-pane.transcript",
  source: `${conversation}transcript.gallery.ts`,
});

export const SCENARIOS: readonly Scenario[] = [
  {
    id: "full-conversation",
    group: "Conversation tour",
    title: "Full conversation",
    entry: "agent-pane.parity-full-conversation",
    source: "src/gallery/parity/fullConversation.gallery.ts",
    variant: "tour",
    inspect:
      "Scroll through one complete conversation: expanded work and commands, final Markdown, a Chief message, nine edited files, a completed subagent with its report, stopped and continued turns, and live Working at the end.",
  },
  {
    id: "working",
    group: "Work headers",
    title: "Working / live work",
    entry: "agent-pane.parity-turn-states",
    source: "src/gallery/parity/turnStates.gallery.ts",
    variant: "working",
    inspect: "A short live turn keeps Working for visible above its activity.",
  },
  {
    id: "completed",
    group: "Work headers",
    title: "Worked for / completed work",
    entry: "agent-pane.parity-turn-states",
    source: "src/gallery/parity/turnStates.gallery.ts",
    variant: "worked",
    inspect: "Worked for 15s and a short final answer fit together. Open the fold to inspect its work.",
  },
  {
    id: "final-answer-streaming",
    group: "Work headers",
    title: "Final answer streaming / frozen work clock",
    entry: "agent-pane.parity-turn-states",
    source: "src/gallery/parity/turnStates.gallery.ts",
    variant: "final-answer-streaming",
    inspect: "The final answer is still streaming. Prior work is folded and its clock stays at 15s.",
  },
  {
    id: "stopped-header",
    group: "Work headers",
    title: "Stopped work / composer Resume",
    entry: "agent-pane.parity-turn-states",
    source: "src/gallery/parity/turnStates.gallery.ts",
    variant: "stopped",
    inspect: "Inspect You stopped after 15s and the composer’s play-shaped Resume control.",
  },
  transcript(
    "conversation",
    "Turns",
    "Completed conversation / plain reply",
    "conversation",
    "Inspect a plain assistant reply and its final answer actions. This fixture has no tool activity.",
  ),
  transcript(
    "codex-live",
    "Turns",
    "Codex live turn",
    "codex-turn-live",
    "Inspect the live tool rows, commentary, Working label, and composer.",
  ),
  transcript(
    "folded",
    "Turns",
    "Completed work folded",
    "collapsed-run",
    "Open and close the real activity disclosure.",
  ),
  transcript(
    "fold-position",
    "Turns",
    "Folding keeps the clicked line",
    "fold-holds-clicked-line",
    "The fixture opens and closes a command. Repeat the interaction while scrolled.",
  ),
  transcript(
    "stopped",
    "Turns",
    "Stopped turn / composer Resume",
    "turn-stopped",
    "Inspect the stopped duration and the play-shaped Resume control in the empty composer.",
  ),
  transcript(
    "continued",
    "Turns",
    "Stopped then continued",
    "turn-stopped-then-continued",
    "Compare the interrupted turn with its follow-up.",
  ),
  transcript(
    "error",
    "Turns",
    "Failed turn",
    "turn-error",
    "Inspect the error and retry controls; retries stay inside the fixture.",
  ),
  transcript(
    "command-live",
    "Commands and files",
    "Running command",
    "shell-live-unwrapped-long-line",
    "Expand the running command and inspect its output and horizontal scroll lane.",
  ),
  transcript(
    "command-done",
    "Commands and files",
    "Completed command",
    "shell-success-output",
    "Expand the completed command; select or copy its output.",
  ),
  transcript(
    "command-failed",
    "Commands and files",
    "Command with nonzero exit",
    "shell-failed-exit",
    "Inspect the exit status and failed command output.",
  ),
  {
    id: "files-reference",
    group: "Commands and files",
    title: "Edited 9 files / reference card",
    entry: "agent-pane.parity-edited-files",
    source: "src/gallery/parity/editedFilesReference.gallery.ts",
    variant: "nine-files",
    inspect:
      "Compare the reference: +129 −5, three file rows, Undo, View changes, and Show 6 more files. Expand and collapse the remaining six.",
  },
  {
    id: "files-two-reference",
    group: "Commands and files",
    title: "Edited 2 files / Codex reference",
    entry: "agent-pane.parity-edited-files",
    source: "src/gallery/parity/editedFilesReference.gallery.ts",
    variant: "two-files",
    inspect:
      "Inspect the nested paths, Undo and View changes. Hover or focus the aggregate totals to reveal View changes and its arrow.",
  },
  transcript(
    "files",
    "Commands and files",
    "Changed files card",
    "edited-files",
    "Open the file card, inspect the edited files, and exercise the mock Undo control.",
  ),
  transcript(
    "diff",
    "Commands and files",
    "Open edit diff",
    "edit-long-line-code",
    "Inspect the real edit preview, selectable diff, wrapping, and scrolling.",
  ),
  transcript(
    "output",
    "Commands and files",
    "Long command output",
    "shell-long-colored-output",
    "Use Show all, Show less, and Wrap lines on the full output fixture.",
  ),
  {
    id: "chief-task",
    group: "Chief and messages",
    title: "Chief long prompt",
    entry: "agent-pane.chief-prompt",
    source: `${conversation}ChiefPromptBubble.gallery.ts`,
    variant: "long",
    inspect: "Inspect Sent from Chief and expand the long task with Show more.",
  },
  {
    id: "chief-context",
    group: "Chief and messages",
    title: "Chief prompt with context",
    entry: "agent-pane.chief-prompt",
    source: `${conversation}ChiefPromptBubble.gallery.ts`,
    variant: "context",
    inspect: "Expand the Chief context and inspect its Copy action.",
  },
  {
    id: "chief-message",
    group: "Chief and messages",
    title: "Incoming message from Chief",
    entry: "agent-pane.incoming-message",
    source: `${conversation}IncomingMessageCard.gallery.ts`,
    variant: "chief",
    inspect: "Inspect the real Chief sender identity, avatar, and incoming message card.",
  },
  {
    id: "long-prompt",
    group: "Chief and messages",
    title: "Long prompt expansion",
    entry: "agent-pane.user-bubble",
    source: `${conversation}UserBubble.gallery.ts`,
    variant: "long-collapsed",
    inspect: "Expand and collapse the long prompt; inspect Copy and Edit.",
  },
  {
    id: "branch",
    group: "Chief and messages",
    title: "Edited prompt and chat branches",
    entry: "agent-pane.user-bubble",
    source: `${conversation}UserBubble.gallery.ts`,
    variant: "running-edit-branches",
    inspect: "Switch prompt branches while one branch runs; inspect the draft and branch spinner.",
  },
  {
    id: "subagent-menu",
    group: "Subagents",
    title: "Subagent row menu",
    entry: "agent-pane.subagent-tray",
    source: `${subagents}SubagentTray.gallery.ts`,
    variant: "row-menu",
    inspect: "The real subagent context menu is open. Inspect its actions and retained cmux icons.",
  },
  {
    id: "subagent-finished",
    group: "Subagents",
    title: "Subagent finished / compact reference",
    entry: "agent-pane.parity-subagent-completion",
    source: "src/gallery/parity/subagentCompletion.gallery.ts",
    variant: "compact",
    inspect:
      "A quiet Settings corner review finished line with no chevron. The name opens the child transcript and report.",
  },
  {
    id: "subagent-lifecycle",
    group: "Subagents",
    title: "Two subagents / started and finished",
    entry: "agent-pane.parity-subagent-completion",
    source: "src/gallery/parity/subagentCompletion.gallery.ts",
    variant: "lifecycle",
    inspect: "Both agents share a start line and keep their finished lines visible. Select a name to open its chat.",
  },
  {
    id: "subagent-finished-report",
    group: "Subagents",
    title: "Subagent finished / report view",
    entry: "agent-pane.parity-subagent-completion",
    source: "src/gallery/parity/subagentCompletion.gallery.ts",
    variant: "report-open",
    inspect: "The completion name opens the child transcript and full report. Use its parent navigation to return.",
  },
  {
    id: "subagent-child",
    group: "Subagents",
    title: "Continue from a subagent",
    entry: "agent-pane.subagents",
    source: `${subagents}subagents.gallery.ts`,
    variant: "child",
    inspect:
      "Inspect the child transcript and composer, then use its parent navigation. This fixture uses the existing Subagent of header.",
  },
  {
    id: "subagent-codex",
    group: "Subagents",
    title: "Codex subagent lineage",
    entry: "agent-pane.subagents",
    source: `${subagents}subagents.gallery.ts`,
    variant: "codex-child",
    inspect: "Inspect a Codex child session and its parent relationship.",
  },
  {
    id: "subagent-report",
    group: "Subagents",
    title: "Completed subagent report",
    entry: "agent-pane.subagent-report",
    source: `${subagents}SubagentReport.gallery.ts`,
    variant: "report-open",
    inspect: "Inspect the expanded report and its completion state.",
  },
  transcript(
    "fork",
    "Subagents",
    "Fork from an earlier turn",
    "fork-any-turn-codex",
    "The fixture invokes Fork against its mock host. Inspect the per-turn fork controls.",
  ),
  {
    id: "question-reference",
    group: "Permissions and history",
    title: "Question prompt / numbered choices",
    entry: "agent-pane.question-prompt-reference",
    source: "src/agent-session/acpmux/question/QuestionPromptReference.gallery.tsx",
    variant: "choices",
    inspect:
      "Choose an option, write a custom answer, fold without answering, or Skip. Independent work and the composer remain usable.",
  },
  {
    id: "question-multiple",
    group: "Permissions and history",
    title: "Question prompt / multiple questions",
    entry: "agent-pane.question-prompt-reference",
    source: "src/agent-session/acpmux/question/QuestionPromptReference.gallery.tsx",
    variant: "multiple",
    inspect: "Use the top-right arrows to navigate three questions. Choices and custom answers survive navigation.",
  },
  {
    id: "question-freeform",
    group: "Permissions and history",
    title: "Question prompt / custom response",
    entry: "agent-pane.question-prompt-reference",
    source: "src/agent-session/acpmux/question/QuestionPromptReference.gallery.tsx",
    variant: "freeform",
    inspect: "Write and send a custom answer without a predefined choice. Closing preserves the unanswered prompt.",
  },
  transcript(
    "permission",
    "Permissions and history",
    "Permission waiting",
    "permission",
    "Inspect Allow once, Always allow, and Deny. All actions use the mock host.",
  ),
  transcript(
    "permission-deny",
    "Permissions and history",
    "Permission denial feedback",
    "permission-deny-feedback",
    "Inspect and edit the denial feedback field.",
  ),
  transcript(
    "auth",
    "Permissions and history",
    "Signed out error",
    "turn-error-signed-out",
    "Inspect the signed-out error state. No real authentication is performed.",
  ),
  transcript(
    "history",
    "Permissions and history",
    "Long virtualized history",
    "long-chat",
    "Scroll through the full history and jump back to the latest turn. This is an inspection fixture, not a performance benchmark.",
  ),
  transcript(
    "history-top",
    "Permissions and history",
    "History scrolled to oldest",
    "scrolling-history",
    "The fixture scrolls to the oldest row. Exercise scrolling and Jump to latest.",
  ),
  {
    ...transcript(
      "replay-tools",
      "Replay",
      "Tools running through completion",
      "conversation",
      "Existing gallery script: commands start and finish, then the final answer arrives. Replay restarts it.",
    ),
    script: "tools",
  },
  {
    ...transcript(
      "replay-stream",
      "Replay",
      "Streaming answer lifecycle",
      "conversation",
      "Existing gallery script: text arrives in small updates and settles into a final answer.",
    ),
    script: "streaming",
  },
  {
    ...transcript(
      "replay-error",
      "Replay",
      "Turn failing during work",
      "conversation",
      "Existing gallery script: a turn starts and finishes with an error card.",
    ),
    script: "error",
  },
  {
    id: "away-recap",
    group: "Permissions and history",
    title: "While you were away / compact bullets",
    entry: "agent-pane.parity-away-recap",
    source: "src/gallery/parity/awayRecap.gallery.ts",
    variant: "latest",
    inspect: "Four recap updates collapse into one current summary with three bullet points.",
  },
  {
    id: "context-restored",
    group: "Permissions and history",
    title: "Reopened chat / saved context",
    entry: "agent-pane.parity-context-usage",
    source: "src/gallery/parity/contextUsage.gallery.ts",
    variant: "restored",
    inspect: "A chat with no live usage event reads 160K / 400K from saved harness counts. Hover shows 40%.",
  },
  {
    id: "context-unknown",
    group: "Permissions and history",
    title: "Chat context / not reported",
    entry: "agent-pane.parity-context-usage",
    source: "src/gallery/parity/contextUsage.gallery.ts",
    variant: "unknown",
    inspect: "A chat with history but no reported counts explains the empty ring on hover.",
  },
  {
    id: "subagent-nested",
    group: "Subagents",
    title: "Subagent with its own child agents",
    entry: "agent-pane.subagents",
    source: `${subagents}subagents.gallery.ts`,
    variant: "child-group",
    inspect:
      "Test coverage spawned Unit tests and Integration tests. Their plain list has no broken card rim or empty row gaps.",
  },
  {
    id: "stack-materials",
    group: "Composer",
    title: "Stacked surfaces / screenshot reproduction",
    entry: "agent-pane.parity-stack-materials",
    source: "src/gallery/parity/stackMaterials.gallery.ts",
    variant: "screenshot",
    background: "busy",
    inspect:
      "The screenshot's pinned ask, goal, question hat, expanded two-running/three-done tray, and composer on one backdrop.",
  },
  {
    id: "background-commands",
    group: "Composer",
    title: "Background commands / one wait and four done",
    entry: "agent-pane.parity-background-work",
    source: "src/gallery/parity/backgroundWork.gallery.ts",
    variant: "commands",
    background: "dark",
    inspect: "Expand five command rows. Their header keeps one terminal icon, including completed commands.",
  },
  {
    id: "background-mixed",
    group: "Composer",
    title: "Commands and subagent logos",
    entry: "agent-pane.parity-background-work",
    source: "src/gallery/parity/backgroundWork.gallery.ts",
    variant: "mixed",
    background: "dark",
    inspect: "Five commands share one terminal header icon alongside the Claude and Codex subagent logos.",
  },
  {
    id: "loop",
    group: "Composer",
    title: "Loop / scheduled check-in",
    entry: "agent-pane.composer-look",
    source: "src/agent-session/acpmux/composerLook.gallery.ts",
    variant: "loop-wakeup",
    background: "dark",
    inspect: "A loop waiting for its next check-in, in the composer's quiet row; its wake prompt is in the tooltip.",
  },
];

export function selectedScenario(id: string | null): Scenario {
  return (
    SCENARIOS.find((scenario) => scenario.id === id) ??
    SCENARIOS.find((scenario) => scenario.id === "full-conversation")!
  );
}

export function scenarioFrame(scenario: Scenario, appearance: "light" | "dark", width: number): string {
  const params = new URLSearchParams({
    entry: scenario.entry,
    entryPath: scenario.source,
    source: scenario.source,
    variant: scenario.variant,
    frame: "component",
    width: String(width),
    colorScheme: appearance,
    theme: appearance === "light" ? "Apple System Colors Light" : "Apple System Colors",
  });
  if (scenario.background) params.set("background", scenario.background);
  if (scenario.script) {
    params.set("script", scenario.script);
    params.set("loop", "0");
  }
  return `/gallery/frame.html?${params}`;
}
