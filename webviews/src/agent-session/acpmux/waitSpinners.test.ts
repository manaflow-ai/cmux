// A wait's spinner goes through WaitSpinner, so a wait that ends inside 300 ms flashes nothing on the
// `wait-spinner-delay` experiment's `delayed` arm (Leo, 2026-11-25: "there are all manner of tips and
// tricks to make it feel so much better than it is"). A bare `<Spinner` is allowed only in the files
// below, each a spinner that marks running work (it should show at once) or one that already holds
// itself back. A new pane spinner fails here until it is a WaitSpinner or named below with why.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = import.meta.dir;

const BARE_SPINNER_OK: Record<string, string> = {
  "PaneLoadingMark.tsx": "already delayed: shows only past 600 ms (cmux#48720)",
  "autoSession/AutoSessionBanner.tsx": "already delayed with useAfterDelay",
  "composer/pasteLoading.tsx": "already delayed: shows only past 400 ms",
  "conversation/DelayedSpinner.tsx": "the Cloud start delay itself (cmux#55978)",
  "conversation/WaitSpinner.tsx": "the wait spinner itself",
  "transcript/OlderLoadingMark.tsx": "shows only once its row is seen while scrolled up",
  "composer/SendSlotGlyph.tsx": "Send's glyph state machine (stopping, pending): its own design",
  "newtab/NewTabScreen.tsx": "Send's starting glyph on a new chat, owned by the cloud-start-just-go experiment",
  "backgroundTasks/SubagentTranscript.tsx": "running work: a subagent or tool call in progress",
  "conversation/AgentCallCard.tsx": "running work: an agent call",
  "conversation/BackgroundTurnLine.tsx": "running work: a background turn",
  "conversation/CapacityWaitCard.tsx": "a long queue wait with its own card",
  "conversation/CompactionNote.tsx": "running work: compaction",
  "conversation/Thinking.tsx": "running work: the turn's start mark",
  "conversation/VersionSwitcher.tsx": "running work: the shown version still streams",
  "session-info/ChildSessionRows.tsx": "running work: a child session working",
  "session-info/WorkflowTasks.tsx": "running work: a workflow task",
  "shell/ShellRow.tsx": "running work: a shell command",
  "started/SessionStatusLine.tsx": "running work: the session's status",
  "subagents/AgentCard.tsx": "running work: a subagent working",
  "subagents/AgentLine.tsx": "running work: a subagent working",
  "summary/StateMark.tsx": "running work: a state mark",
  "summary/WorkflowSideTab.tsx": "running work: a workflow step",
  "summary/WorkflowSummary.tsx": "running work: a workflow",
  "toolCards/ToolCards.tsx": "running work: a tool card",
  "worktreeSetup.tsx": "running work: a setup step",
};

function* sources(dir: string): Generator<string> {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== "generated") yield* sources(path);
    } else if (/\.tsx$/.test(name) && !/\.(?:test|gallery)\.tsx$/.test(name)) yield path;
  }
}

test("every bare pane spinner marks running work or already holds itself back", () => {
  const bare = new Set<string>();
  for (const file of sources(ROOT)) if (/<Spinner\b/.test(readFileSync(file, "utf8"))) bare.add(relative(ROOT, file));
  const unnamed = [...bare].filter((file) => !(file in BARE_SPINNER_OK));
  expect(unnamed).toEqual([]);
  // A file named here that no longer draws a bare spinner leaves the list.
  expect(Object.keys(BARE_SPINNER_OK).filter((file) => !bare.has(file))).toEqual([]);
});
